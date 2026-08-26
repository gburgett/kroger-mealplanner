# Architecture Decision Records

Each significant architectural decision has a record in this folder.

* Format: [MADR 4](https://adr.github.io/madr/), with the front matter block.
* Language: [ASD-STE100 Simplified Technical English](https://asd-ste100.org/).
  Write short sentences. Use the active voice. Use one word for one meaning.
* Filename: `NNNN-title-with-hyphens.md`. The number increments by one.
* Status: `proposed`, `accepted`, `rejected`, `deprecated` or
  `superseded by ADR-NNNN`.

A record does not change after it has the status `accepted`. To change a
decision, write a new record. Give the old record the status
`superseded by ADR-NNNN`.

| ADR | Title | Status |
| --- | --- | --- |
| [0001](0001-use-agentos-for-the-sandbox.md) | Use agentOS for the sandbox | superseded by ADR-0005 |
| [0002](0002-use-typescript-for-the-mcp-server.md) | Use TypeScript on Node.js for the MCP server | accepted |
| [0003](0003-use-rust-for-the-mealplan-cli.md) | Use Rust for the mealplan CLI | superseded by ADR-0007 |
| [0004](0004-use-pnpm-for-node-dependencies.md) | Use pnpm for Node.js dependencies | accepted |
| [0005](0005-use-microsandbox-for-the-sandbox.md) | Use microsandbox for the sandbox | superseded by ADR-0008 |
| [0006](0006-the-sandbox-has-no-interpreter-and-no-network-client.md) | The sandbox has no interpreter and no network client | accepted |
| [0007](0007-build-the-mealplan-cli-for-native-linux.md) | Build the mealplan CLI for native Linux | accepted |
| [0008](0008-use-bubblewrap-for-the-sandbox.md) | Use bubblewrap for the sandbox, and leave multi-tenancy open | accepted |
| [0009](0009-authenticate-the-mcp-server-with-oauth.md) | Authenticate the MCP server with OAuth, and guard the consent page with exe.dev | accepted |
| [0010](0010-send-the-shopping-list-to-a-kroger-cart.md) | Send the shopping list to a Kroger cart from the server, not from the sandbox | accepted, one item open |
| [0011](0011-ask-kroger-for-only-the-cart-scope.md) | Ask Kroger for only the cart scope | accepted |

Longer investigations that feed a decision live beside this folder as trade studies
and spikes: `../sandbox-trade-study.md`, `../agent-runtime-spike.md` and
`../bubblewrap-lockdown-study.md`. Plans that follow from a decision live in
`../plans/`.
