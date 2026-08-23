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
| [0001](0001-use-agentos-for-the-sandbox.md) | Use agentOS for the sandbox | accepted |
| [0002](0002-use-typescript-for-the-mcp-server.md) | Use TypeScript on Node.js for the MCP server | accepted |
| [0003](0003-use-rust-for-the-mealplan-cli.md) | Use Rust for the mealplan CLI | accepted |
