---
status: accepted
date: 2026-08-23
decision-makers: gburgett
consulted: ADR 0001, ADR 0002
informed: all contributors
---

# Use Rust for the mealplan CLI

## Context and Problem Statement

The `mealplan` CLI has two commands. `mealplan validate` tests the meal-plan
folder against the document format. `mealplan shopping-list` reads the dinners
in a date range, it follows the links to the recipes, it scales the quantities,
and it adds them together.

These are the only two operations that bash cannot do. The agent runs `mealplan
validate` after almost every write, thus the CLI starts many times in one
session. Speed is a requirement.

The CLI runs in the sandbox. ADR 0001 selected agentOS, and **agentOS runs Linux
on WebAssembly. Each command must be cross-compiled to WebAssembly.** A native
Linux binary does not operate in the sandbox. This is the primary constraint on
the language.

Which language must the CLI use?

## Decision Drivers

* The CLI must start quickly. The start time is more important than the
  calculation speed. The corpus of one household is small. A large corpus has
  approximately 3000 documents.
* The language must compile to the `wasm32-wasip1` target. This is a
  requirement, not a preference.
* The language must also compile to native Linux. ADR 0001 has an exit to
  gVisor. If that exit is used, the same source must give a native binary.
* The arithmetic must be exact. A shopping list that shows
  `0.30000000000000004 cup` is a defect.
* The error messages must name the file and the line. This needs good control of
  the parser.

## Considered Options

* Rust
* Go
* TypeScript, on the V8 runtime in the sandbox
* C or Zig

## Decision Outcome

Chosen option: "Rust", because it gives the smallest WebAssembly module and the
shortest start time, and because it satisfies all the other drivers.

Rust has no garbage collector and no runtime to start. The module contains only
the program. Rust also compiles to native Linux from the same source, thus the
gVisor exit in ADR 0001 stays open.

The agentOS ecosystem agrees with this choice. agentOS is written in Rust. The
registry packages that agentOS supplies, such as `ripgrep`, are compiled tools
of the same type. The path from Rust to a WebAssembly command is the usual path
in this environment.

### Consequences

* Good, because the module is small and the start time is short. Go gives a
  module of 2.4 MB for a program that prints one line. This is measured on this
  machine with Go 1.27. The Go runtime and the garbage collector cause this
  size, and `-ldflags="-s -w"` does not decrease it.
* Good, because `rust_decimal` or `num-rational` give exact arithmetic. The
  scenarios in `features/shopping_list.feature` need `8 tbsp + 0.5 cup = 1 cup`,
  not an approximation.
* Good, because all knowledge of the document format stays in one program. The
  server does not read the corpus. It only runs commands. Thus there is one
  parser, and the format cannot become different in two places.
* Good, because the same source gives a native binary. The Cucumber suite can
  test the CLI directly, and the gVisor exit stays open.
* Bad, because Rust is a second toolchain and a second language. ADR 0002
  selected TypeScript for the server.
* Bad, because Rust is not installed on this machine. An installation of
  `rustup` and the `wasm32-wasip1` target is necessary.
* Bad, because Rust is more difficult to write than Go. The two commands are
  small, thus this cost is limited.
* Neutral, because the start time of Rust in agentOS is not measured. See
  "Confirmation".

### Confirmation

The claim about speed is not yet measured. Measure it before you write the full
CLI.

1. Build a program in Rust that prints one line. Build it for
   `wasm32-wasip1`. Record the size of the module.
2. Measure the start time of that module in agentOS. Compare it with the Go
   module of 2.4 MB.
3. If the Rust start time is not better than the Go start time by a useful
   quantity, change this decision to Go. Go is simpler and it is installed
   already. Write a new ADR.
4. The scenarios in `features/corpus.feature`, `features/shopping_list.feature`
   and `features/pantry.feature` are the functional confirmation. They contain
   the exact arithmetic and the exact error messages.

## Pros and Cons of the Options

### Rust

* Good, because there is no garbage collector and no runtime to start.
* Good, because the WebAssembly module is small.
* Good, because agentOS and its registry tools use the same path.
* Good, because the compiler prevents many errors in a parser.
* Bad, because it is a second toolchain.
* Bad, because it is more difficult to write than Go.

### Go

* Good, because Go is installed on this machine already.
* Good, because Go is simple to write and simple to read.
* Good, because `math/big.Rat` in the standard library gives exact arithmetic.
* Bad, because the smallest `wasm32-wasip1` module is 2.4 MB. This is measured.
  The garbage collector and the scheduler must start each time.
* Neutral, because TinyGo gives smaller modules. TinyGo does not support all of
  the standard library, and the parser needs `encoding/json` behaviour.

### TypeScript, on the V8 runtime in the sandbox

* Good, because it uses one language for the server and the CLI.
* Good, because agentOS executes guest JavaScript on native V8 with the JIT
  compiler. The JavaScript is not WebAssembly.
* Bad, because the runtime must start for each invocation. This is the slowest
  option, and speed is the primary driver for the CLI.
* Bad, because floating point arithmetic is not exact. A decimal library is
  necessary.

### C or Zig

* Good, because the modules are the smallest and the start time is the shortest.
* Bad, because a parser for YAML and markdown in C is difficult and unsafe. The
  benefit against Rust is very small.

## More Information

The two languages have different drivers, and this is correct:

| Component | Primary driver | Language |
| --- | --- | --- |
| MCP server | simplicity | TypeScript (ADR 0002) |
| `mealplan` CLI | speed in a WebAssembly sandbox | Rust (this ADR) |

The interface between them is a command line and an exit status. There is no
shared library and no shared type. Thus the two languages do not increase the
complexity of the system.

Examine this ADR again if the measurements in "Confirmation" do not agree with
it, or if ADR 0001 is superseded.
