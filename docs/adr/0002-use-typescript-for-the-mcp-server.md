---
status: superseded by ADR-0020
date: 2026-08-23
decision-makers: gburgett
consulted: ADR 0001
informed: all contributors
---

# Use TypeScript on Node.js for the MCP server

## Context and Problem Statement

The MCP server speaks the MCP protocol to a client. It opens a sandbox for a
tenant, it runs commands in the sandbox, and it commits the changes to git. The
server does no other work.

ADR 0001 selected agentOS for the sandbox. agentOS is a Node.js library. The
server must load this library in its own process. Thus the server must be a
Node.js program.

Which language must the server use, and which build tools?

## Decision Drivers

* Simplicity is the most important driver. The server is a thin layer.
* The server must load the agentOS library in its own process.
* The MCP protocol needs an SDK. A first-party SDK is better than a community
  SDK.
* The tool schemas must be correct. The agent reads them as documentation.
* The Cucumber specifications must drive a real MCP client.

## Considered Options

* TypeScript on Node.js, with no build step
* TypeScript on Node.js, with a build step
* JavaScript on Node.js
* A different language, with a Node.js process for agentOS

## Decision Outcome

Chosen option: "TypeScript on Node.js, with no build step", because it is the
simplest option that keeps the types of the tool schemas.

Node.js 24 executes a `.ts` file directly. It removes the types and it runs the
file. A compiler, a bundler and a `tsconfig.json` are not necessary. This is
measured on this machine: `node t.ts` gives the correct output with Node.js
v24.19.0.

### Consequences

* Good, because `node server.ts` is the only command to start the server. There
  is no build step and there is no build folder.
* Good, because the MCP TypeScript SDK is first-party. The agentOS library is
  also TypeScript. Both give types.
* Good, because the types make the tool schemas and the sandbox session
  interface explicit.
* Good, because `@cucumber/cucumber` is a first-class Cucumber runtime. The step
  definitions can use the same MCP SDK as a real client.
* Good, because one process holds the server and the sandbox. A second process
  and an RPC layer are not necessary.
* Bad, because the type removal in Node.js does not support all TypeScript
  features. Enums and namespaces do not operate. Use plain types.
* Bad, because Node.js is slower than a compiled language. This is acceptable.
  The server does no calculation. The work is in the sandbox.
* Neutral, because the corpus documents are not parsed here. ADR 0003 puts all
  knowledge of the document format in the `mealplan` CLI.

### Confirmation

1. The MCP scenarios in `features/sandbox.feature` must pass. These scenarios
   use a real MCP client over a real transport.
2. `node server.ts` must start the server. A build command must not be
   necessary.

## Pros and Cons of the Options

### TypeScript on Node.js, with no build step

* Good, because there is no build step.
* Good, because the types stay.
* Bad, because some TypeScript features do not operate.

### TypeScript on Node.js, with a build step

* Good, because all TypeScript features operate.
* Bad, because a compiler, a configuration file and a build folder are
  necessary. This is more complex, and simplicity is the most important driver.

### JavaScript on Node.js

* Good, because it is the simplest option.
* Bad, because the tool schemas and the session interface have no types. The
  agent reads the tool schemas as documentation. Errors in them are expensive.

### A different language, with a Node.js process for agentOS

* Good, because the server language becomes free.
* Bad, because two processes and an RPC layer between them are necessary. This
  is the most complex option and it gives no benefit.

## More Information

ADR 0001 made this decision almost automatic. The ADR records it because a
contributor will ask why the server is TypeScript.

ADR 0003 selects the language of the `mealplan` CLI. That decision has different
drivers and it has a different result.
