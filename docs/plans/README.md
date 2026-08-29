# Plans

A plan is how an accepted decision gets built. It decides nothing.

If a plan finds itself arguing a trade-off, that argument belongs in an ADR under
`../adr/`, and the evidence belongs in a study beside it. A plan may be edited freely
and deleted once its work is done — that is the difference between a plan and a record.

- Filename: `NNNN-title-with-hyphens.md`. The number increments by one.
- Every plan names, at the top, the ADRs it implements and its definition of done.
- Ordinary prose, not [ASD-STE100](https://asd-ste100.org/). That constraint is for the
  records, which have to stay readable for years.

| Plan | Title | Status |
| --- | --- | --- |
| [0001](0001-implement-the-core-features.md) | Implement the core features | done, 2026-08-23 |
| [0002](0002-authenticate-the-mcp-server.md) | Authenticate the MCP server | done, 2026-08-23, except Phase 0 |
| [0003](0003-send-the-shopping-list-to-a-kroger-cart.md) | Send the shopping list to a Kroger cart | done, 2026-08-25, except one Phase 0 measurement |
| [0004](0004-import-pinterest-boards.md) | Import boards from Pinterest as pins-and-links | proposed, not started |
