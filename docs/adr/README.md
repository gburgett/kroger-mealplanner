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
| [0010](0010-send-the-shopping-list-to-a-kroger-cart.md) | Send the shopping list to a Kroger cart from the server, not from the sandbox | accepted; open item closed by ADR-0012 |
| [0011](0011-ask-kroger-for-only-the-cart-scope.md) | Ask Kroger for only the cart scope | accepted |
| [0012](0012-refuse-a-second-send-of-a-shopping-list.md) | Refuse a second send of a shopping list, because Kroger adds to the quantity | accepted |
| [0013](0013-record-household-preferences-as-prose-with-no-schema.md) | Record household preferences as prose with no schema | accepted |
| [0014](0014-split-the-pantry-into-staples-and-rechecked-consumables.md) | Split the pantry into staples and rechecked consumables | accepted |
| [0015](0015-mark-a-consumable-bought-from-the-kroger-send.md) | Mark a consumable bought from the Kroger cart send | accepted |
| [0016](0016-mark-and-gate-a-consumable-that-needs-a-recheck.md) | Mark and gate a consumable that needs a recheck | accepted |
| [0017](0017-shop-at-walmart-through-the-affiliate-api-with-a-link-for-the-cart.md) | Shop at Walmart through the affiliate API, with a link for the cart | accepted |
| [0018](0018-run-a-weekly-llm-job-to-recheck-consumables.md) | Run a weekly LLM job to recheck consumables | proposed |
| [0019](0019-import-pinterest-boards-as-a-pins-and-links-ledger.md) | Import Pinterest boards as a pins-and-links ledger the agent converts | proposed |
| [0020](0020-migrate-the-server-and-jobs-to-elixir-phoenix-and-postgres.md) | Migrate the MCP server and the weekly job to Elixir, Phoenix and PostgreSQL | proposed; unblocked by ADR 0021; PostgreSQL superseded by ADR-0024 |
| [0021](0021-reach-the-corpus-only-through-the-sandbox-session.md) | Reach the corpus only through the sandbox session | accepted |
| [0022](0022-run-the-scenarios-in-process-with-a-host-sandbox-mode-for-ci.md) | Run the scenarios in process, with a host sandbox mode for CI | accepted |
| [0023](0023-drive-the-screens-the-transport-and-the-third-parties-over-real-http-in-test.md) | Drive the screens, the transport and the third parties over real HTTP in test | accepted |
| [0024](0024-keep-the-server-state-in-sqlite.md) | Keep the server state in SQLite, in one file beside the meal-plan folder | accepted |
| [0025](0025-run-the-suite-as-one-process-not-partitioned-workers.md) | Run the suite as one process, not partitioned workers | accepted |
| [0026](0026-onboard-a-new-household-through-tool-results-not-the-handshake.md) | Onboard a new household through tool-call results, not the handshake, and add the public install page Phase 8 left open | proposed |

Longer investigations that feed a decision live beside this folder as trade studies
and spikes: `../sandbox-trade-study.md`, `../agent-runtime-spike.md`,
`../bubblewrap-lockdown-study.md` and `../test-suite-parallelisation-study.md`. Plans that follow from a decision live in
`../plans/`.
