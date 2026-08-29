// The exe.dev LLM gateway, stood in for. The third mock this project has, in
// the one shape the rule permits: a third-party HTTP API, one file, a real
// listener on a real port. features/support/kroger.ts and
// features/support/walmart.ts are the other two, and there are no more seams.
//
// A scenario scripts the turns the model will answer with, in order — an
// end_turn with some text, or a tool_use naming one of the job's three tools.
// The mock never generates anything: what comes back is exactly what was
// scripted, which is what makes "the job asked for exactly these tool calls,
// in this order, and stopped" something a scenario can assert. See ADR 0018.

import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import type { AddressInfo } from 'node:net';

export type ScriptedTurn =
  | { kind: 'end_turn'; text: string }
  | { kind: 'tool_use'; name: string; input: unknown; repeatForever?: boolean };

const ANTHROPIC_VERSION = '2023-06-01';

export class LlmMock {
  readonly base: string;
  readonly #http: Server;

  /** Every request body this mock received, in order — parsed JSON. */
  readonly requests: unknown[] = [];

  #turns: ScriptedTurn[] = [];
  #issued = 0;

  private constructor(base: string, http: Server) {
    this.base = base;
    this.#http = http;
  }

  static async start(): Promise<LlmMock> {
    let mock: LlmMock;
    const http = createServer((request, response) => {
      mock.#handle(request, response).catch((error: unknown) => {
        response.writeHead(500, { 'content-type': 'text/plain' });
        response.end(String(error));
      });
    });
    http.on('connection', (socket) => socket.setNoDelay(true));
    await new Promise<void>((resolve) => http.listen(0, '127.0.0.1', resolve));
    const port = (http.address() as AddressInfo).port;
    mock = new LlmMock(`http://127.0.0.1:${port}`, http);
    return mock;
  }

  async stop(): Promise<void> {
    this.#http.closeIdleConnections?.();
    this.#http.closeAllConnections?.();
    await new Promise<void>((resolve) => this.#http.close(() => resolve()));
  }

  // --- scripting -------------------------------------------------------------

  /** The model ends its turn with nothing further to do. */
  scriptEndTurn(text = 'nothing here needs a recheck this week'): void {
    this.#turns.push({ kind: 'end_turn', text });
  }

  /**
   * The model calls one tool, and then ends its turn.
   *
   * A single scripted call is the common case: script the call, get the
   * result, stop. Scenarios that need more than one turn call this, or
   * scriptForever, more than once.
   */
  scriptToolUse(name: string, input: unknown): void {
    this.#turns.push({ kind: 'tool_use', name, input });
  }

  /**
   * The model keeps calling the same tool forever, never ending its turn.
   *
   * For the runaway scenario: the job's own turn ceiling has to be what stops
   * this, not the mock running out of scripted turns.
   */
  scriptForever(name: string, input: unknown): void {
    this.#turns.push({ kind: 'tool_use', name, input, repeatForever: true });
  }

  /** Every request's body, flattened to text, for a "mentions X" assertion. */
  get requestText(): string {
    return this.requests.map((request) => JSON.stringify(request)).join('\n');
  }

  // --- the endpoint ------------------------------------------------------------

  async #handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const url = new URL(request.url ?? '/', this.base);

    if (url.pathname !== '/v1/messages' || request.method !== 'POST') {
      fail(response, 404, `the LLM mock has no ${request.method} ${url.pathname}`);
      return;
    }
    if (request.headers['anthropic-version'] !== ANTHROPIC_VERSION) {
      fail(response, 400, `missing or wrong anthropic-version header`);
      return;
    }

    this.requests.push(JSON.parse((await body(request)) || '{}'));

    const turn = this.#nextTurn();
    if (!turn) {
      fail(response, 500, 'the LLM mock has no scripted turn left to answer with');
      return;
    }

    this.#issued += 1;
    if (turn.kind === 'end_turn') {
      json(response, 200, {
        id: `msg_${this.#issued}`,
        type: 'message',
        role: 'assistant',
        content: [{ type: 'text', text: turn.text }],
        stop_reason: 'end_turn',
      });
      return;
    }

    json(response, 200, {
      id: `msg_${this.#issued}`,
      type: 'message',
      role: 'assistant',
      content: [{ type: 'tool_use', id: `toolu_${this.#issued}`, name: turn.name, input: turn.input }],
      stop_reason: 'tool_use',
    });
  }

  #nextTurn(): ScriptedTurn | undefined {
    const next = this.#turns[0];
    if (!next) return undefined;
    if (!next.repeatForever) this.#turns.shift();
    return next;
  }
}

// --- the plumbing ------------------------------------------------------------

async function body(request: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of request) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks).toString('utf8');
}

function json(response: ServerResponse, status: number, payload: unknown): void {
  response.writeHead(status, { 'content-type': 'application/json' });
  response.end(JSON.stringify(payload));
}

function fail(response: ServerResponse, status: number, message: string): void {
  json(response, status, { type: 'error', error: { type: 'invalid_request_error', message } });
}
