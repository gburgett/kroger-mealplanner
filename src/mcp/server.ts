// The MCP server. One process holds the server and the sandbox: run() is a
// bubblewrap child, so there is no daemon, no RPC and no KVM. See ADR 0002 and
// ADR 0008.
//
// The transport is MCP Streamable HTTP bound to loopback, so a Cucumber `When`
// step is a genuine web request against the real API rather than a function
// call that skips the transport.

import { randomUUID } from 'node:crypto';
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import type { AddressInfo } from 'node:net';

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';

import { scaffold } from '../corpus/scaffold.ts';
import { commitAfterEveryCommand, commitIfChanged } from '../git/commit.ts';
import { ensureRepository, type Clock } from '../git/repository.ts';
import { open, type Session, type SessionOptions } from '../sandbox/session.ts';
import {
  BASH_DESCRIPTION,
  READ_FILE_DESCRIPTION,
  WRITE_FILE_DESCRIPTION,
  bashInputSchema,
  bashOutputSchema,
  readCorpusFile,
  readFileInputSchema,
  readFileOutputSchema,
  renderBashResult,
  runBash,
  writeCorpusFile,
  writeFileInputSchema,
  writeFileOutputSchema,
} from './tools.ts';

export const MCP_PATH = '/mcp';

export type ServerOptions = Omit<SessionOptions, 'tenant'> & {
  tenant?: string;
  host?: string;
  /** 0 asks the operating system for a free port, which is what the tests want. */
  port?: number;
  /** Frozen by the scenarios so git dates are deterministic. */
  now?: Clock;
};

export type RunningServer = {
  url: string;
  port: number;
  session: Session;
  close(): Promise<void>;
};

export async function startServer(options: ServerOptions): Promise<RunningServer> {
  const tenant = options.tenant ?? 'household';
  const now = options.now ?? (() => new Date());

  const session = await open({ ...options, tenant });
  // The folder first, then the repository, so the first commit holds the
  // scaffold rather than an empty tree.
  await scaffold(session.folder);
  await ensureRepository(session, now);
  // From here on, every command that changes a file commits itself.
  commitAfterEveryCommand(session, now);

  const transports = new Map<string, StreamableHTTPServerTransport>();

  const http = createServer((request, response) => {
    handle(request, response, session, transports, options.folder, now).catch((error: unknown) => {
      if (!response.headersSent) {
        response.writeHead(500, { 'content-type': 'application/json' });
      }
      response.end(
        JSON.stringify({
          jsonrpc: '2.0',
          error: { code: -32603, message: error instanceof Error ? error.message : String(error) },
          id: null,
        }),
      );
    });
  });

  // Nagle's algorithm against delayed ACK costs about 38 ms on every single
  // call — the reply's headers and body go out as separate segments, and the
  // second one waits. Measured: 47.7 ms per tool call with it, 10 ms without.
  // The command itself is 9.7 ms, so this was four fifths of what a person
  // would have felt.
  http.on('connection', (socket) => socket.setNoDelay(true));

  // Loopback only. The sandbox is the boundary for the agent; this is the
  // boundary for the transport, and the product is one household on one
  // machine.
  const host = options.host ?? '127.0.0.1';
  await new Promise<void>((resolve) => http.listen(options.port ?? 0, host, resolve));
  const port = (http.address() as AddressInfo).port;

  return {
    url: `http://${host}:${port}${MCP_PATH}`,
    port,
    session,
    async close() {
      for (const transport of transports.values()) {
        await transport.close().catch(() => undefined);
      }
      transports.clear();
      await new Promise<void>((resolve) => http.close(() => resolve()));
      await closeIdle(http);
      await session.close();
    },
  };
}

async function handle(
  request: IncomingMessage,
  response: ServerResponse,
  session: Session,
  transports: Map<string, StreamableHTTPServerTransport>,
  folder: string,
  now: Clock,
): Promise<void> {
  const url = new URL(request.url ?? '/', 'http://localhost');
  if (url.pathname !== MCP_PATH) {
    response.writeHead(404, { 'content-type': 'text/plain' });
    response.end(`no such path: ${url.pathname}. The MCP endpoint is ${MCP_PATH}.\n`);
    return;
  }

  const header = request.headers['mcp-session-id'];
  const sessionId = Array.isArray(header) ? header[0] : header;
  const existing = sessionId ? transports.get(sessionId) : undefined;
  if (existing) {
    await existing.handleRequest(request, response);
    return;
  }

  if (sessionId) {
    response.writeHead(404, { 'content-type': 'text/plain' });
    response.end(`unknown MCP session: ${sessionId}\n`);
    return;
  }

  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: () => randomUUID(),
    onsessioninitialized: (id: string) => transports.set(id, transport),
    // Every tool here is request/response and there is nothing to stream, so
    // a plain JSON reply rather than an SSE stream for each call.
    enableJsonResponse: true,
  });
  transport.onclose = () => {
    if (transport.sessionId) transports.delete(transport.sessionId);
  };

  const mcp = buildMcpServer(session, folder, now);
  await mcp.connect(transport);
  await transport.handleRequest(request, response);
}

export function buildMcpServer(session: Session, folder: string, now: Clock): McpServer {
  const mcp = new McpServer(
    { name: 'kroger-mealplanner', version: '0.1.0' },
    {
      capabilities: { tools: {} },
      instructions:
        'A meal plan is a folder of markdown documents. Read README.md in the folder first; ' +
        'it is the schema. Plan meals with ordinary shell commands.',
    },
  );

  mcp.registerTool(
    'bash',
    {
      title: 'Run a shell command in the sandbox',
      description: BASH_DESCRIPTION,
      inputSchema: bashInputSchema,
      outputSchema: bashOutputSchema,
    },
    async ({ command }) => {
      const result = await runBash(session, command);
      return {
        content: [{ type: 'text', text: renderBashResult(result) }],
        structuredContent: result,
        isError: result.exitCode !== 0,
      };
    },
  );

  mcp.registerTool(
    'read_file',
    {
      title: 'Read a file from the meal-plan folder',
      description: READ_FILE_DESCRIPTION,
      inputSchema: readFileInputSchema,
      outputSchema: readFileOutputSchema,
    },
    async ({ path: requested }) => {
      const content = await readCorpusFile(folder, requested);
      return {
        content: [{ type: 'text', text: content }],
        structuredContent: { content },
      };
    },
  );

  mcp.registerTool(
    'write_file',
    {
      title: 'Create or overwrite a file in the meal-plan folder',
      description: WRITE_FILE_DESCRIPTION,
      inputSchema: writeFileInputSchema,
      outputSchema: writeFileOutputSchema,
    },
    async ({ path: requested, content }) => {
      // Written and committed under one turn of the session, so a bash command
      // arriving in between cannot be committed under this message.
      const bytes = await session.enqueue(async () => {
        const written = await writeCorpusFile(folder, requested, content);
        await commitIfChanged(session, `write_file ${requested}`, now());
        return written;
      });
      return {
        content: [{ type: 'text', text: `wrote ${bytes} bytes to ${requested}` }],
        structuredContent: { path: requested, bytes },
      };
    },
  );

  return mcp;
}

/** node:http keeps keep-alive sockets open past close(); the tests must not hang. */
async function closeIdle(http: Server): Promise<void> {
  http.closeIdleConnections?.();
  http.closeAllConnections?.();
}
