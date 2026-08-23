---
status: accepted
date: 2026-08-23
decision-makers: gburgett
consulted: agent runtime spike (docs/agent-runtime-spike.md)
informed: all contributors
supersedes: ADR-0003
---

# Build the mealplan CLI for native Linux

## Context and Problem Statement

ADR 0003 chose Rust for the `mealplan` command. It also made `wasm32-wasip1` a hard
requirement, and it gave the reason:

> agentOS runs Linux on WebAssembly. Each command must be cross-compiled to
> WebAssembly. A native Linux binary does not operate in the sandbox.

ADR 0005 replaced agentOS with microsandbox. A microVM runs a true Linux kernel. The
reason above is void.

ADR 0003 also demanded a measurement before the full CLI is written: build a
hello-world for `wasm32-wasip1`, and compare its size and start time with the 2.4 MB
Go module. That measurement answered a question about a WebAssembly sandbox. There is
no WebAssembly sandbox now.

Which target must the CLI use?

## Decision Drivers

* The command must run in the sandbox of ADR 0005.
* The command must start fast. The shopping list is one command, but `validate` runs
  after most edits.
* The arithmetic must be exact. `8 tbsp + 0.5 cup` must give `1 cup`.
  `0.30000000000000004 cup` is a defect.
* Error messages must name the file and the line.
* The build must be simple. One toolchain, one target.
* The corpus parser must exist in one place only.

## Considered Options

* Rust for `x86_64-unknown-linux-musl`
* Rust for `wasm32-wasip1`, as ADR 0003 says
* Go for native Linux

## Decision Outcome

Chosen option: "Rust for `x86_64-unknown-linux-musl`", because the language choice of
ADR 0003 holds and only its target was tied to agentOS.

What carries over from ADR 0003, unchanged:

* Rust, for the small binary, the fast start and the exact arithmetic.
* Exactly two commands: `mealplan validate [path]` and
  `mealplan shopping-list --from --to`.
* Exact arithmetic with `rust_decimal` or `num-rational`.
* Error messages name the file and the line.
* The corpus parser exists **only** in this CLI. The server never reads a recipe.
* The interface between the two languages is a command line and an exit status. There
  is no shared library and no shared type.

What changes:

* The target is `x86_64-unknown-linux-musl`, not `wasm32-wasip1`.
* The `wasm32-wasip1` target is not installed and not built.
* The measurement ADR 0003 demanded is cancelled. It compared two WebAssembly modules
  for a WebAssembly sandbox.

`musl` gives one static binary. The sandbox image of ADR 0006 is small, and a static
binary needs nothing from it.

### Consequences

* Good, because one target, not two. ADR 0003 needed both WebAssembly and native
  Linux, because the specifications had to run the CLI directly and gVisor had to stay
  possible. One target now serves both.
* Good, because Cucumber can run the same binary the sandbox runs.
* Good, because a native binary starts faster than a WebAssembly module.
* Good, because the crate may use any crate. A WebAssembly target restricts the
  crates that are available.
* Bad, because the binary must enter the sandbox image at build time. ADR 0006 names
  it as a program in the image.
* Bad, because a future move to a WebAssembly sandbox must build for WebAssembly
  again. Keep the crate free of code that only a real operating system supplies.
* Neutral, because Rust is still not installed on this machine. `rustup` and the
  `x86_64-unknown-linux-musl` target must be installed.

### Confirmation

1. `cargo build --release --target x86_64-unknown-linux-musl` must give one static
   binary.
2. The scenarios in `features/corpus.feature`, `features/shopping_list.feature` and
   `features/pantry.feature` are the functional confirmation. They hold the exact
   arithmetic and the exact error messages.
3. The `mealplan` scenarios must run through the sandbox, not against the binary on
   the host. The rule in `AGENTS.md` says a `When` step goes through the real MCP
   server.

## More Information

`docs/agent-runtime-spike.md`, Part 4, records why the premise of ADR 0003 is void.
