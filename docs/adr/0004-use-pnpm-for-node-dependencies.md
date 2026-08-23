---
status: accepted
date: 2026-08-23
decision-makers: gburgett
consulted: ADR 0001, ADR 0002
informed: all contributors
---

# Use pnpm for Node.js dependencies

## Context and Problem Statement

ADR 0002 selected TypeScript on Node.js for the MCP server. The server loads the
agentOS library and the MCP SDK. Thus the server has dependencies from the npm
registry.

ADR 0001 recorded a risk in its consequences: the agentOS installation downloads
1.5 GB of dependencies. These include `googleapis` and the Anthropic SDK. This
is a large supply chain.

The risk is not equal to the risk in the sandbox. **The dependencies of the
server execute outside the sandbox.** The sandbox holds the agent. It does not
hold our own dependencies. A malicious package executes in the server process,
and that process holds the credentials of each tenant. The sandbox gives no
protection against this.

Which package manager must the server use?

## Decision Drivers

* The package manager must decrease the risk of an attack through the supply
  chain.
* The package manager must not execute code from a dependency at installation
  time without permission. Most attacks on the npm registry execute in a
  lifecycle script.
* The lockfile must be exact. It must contain an integrity value for each
  package.
* A package must only import what it declares.
* The result must stay simple. Simplicity is the primary driver of ADR 0002.

## Considered Options

* pnpm
* npm
* Yarn
* Bun
* Vendored dependencies, in the repository

## Decision Outcome

Chosen option: "pnpm", because it blocks lifecycle scripts by default, it delays
new versions of a package, and it gives a strict layout of `node_modules`.

pnpm 11 makes these protections the default. They are not optional settings that
a contributor can forget.

| Setting | Default | Effect |
| --- | --- | --- |
| `allowBuilds` | empty | A dependency cannot execute a build script. You must permit each package. |
| `minimumReleaseAge` | 1440 minutes | pnpm does not resolve a version that is less than one day old. |
| `blockExoticSubdeps` | true | pnpm blocks unusual types of subdependency. |
| `strictDepBuilds` | true | pnpm stops the installation if a package needs a build that you did not permit. |

`pnpm-workspace.yaml` in this repository holds these settings. It makes
`minimumReleaseAge` longer than the default.

### Consequences

* Good, because a lifecycle script cannot execute without permission. This is
  the usual method of an attack through the npm registry, and it is the method
  that gives the attacker the credentials in the server process.
* Good, because `minimumReleaseAge` gives a delay. An attacker publishes a
  malicious version, and the registry removes it after some hours. A delay of
  seven days puts our installation after that removal.
* Good, because the layout of `node_modules` is strict. A package can only
  import what it declares. A phantom dependency cannot occur.
* Good, because the store keeps one copy of each package. The 1.5 GB from ADR
  0001 occupies the disk one time, not one time for each project.
* Good, because `pnpm-lock.yaml` contains an integrity value for each package.
* Bad, because pnpm is not installed on this machine. Corepack must enable it.
  Corepack is available with Node.js 24.
* Bad, because `minimumReleaseAge` also delays a correction that we want. To
  install a new version immediately, set `minimumReleaseAge: 0` for a short
  time, then put the value back.
* Bad, because `allowBuilds` needs maintenance. agentOS or one of its
  dependencies can need a build script. A contributor must examine the package
  and then add it.
* Bad, because a package manager does not read the code of a package. pnpm does
  not stop a malicious package that we import and then call. **pnpm decreases
  this risk. It does not remove it.**

### Confirmation

1. `pnpm-workspace.yaml` is in the repository, and it contains the settings
   above.
2. When `package.json` exists, it must contain a `packageManager` field with an
   exact version of pnpm. Corepack then uses that version.
3. `pnpm-lock.yaml` must be in the repository.
4. An automatic build must use `pnpm install --frozen-lockfile`. This command
   fails if the lockfile does not agree with `package.json`.
5. `node_modules` must not be in the repository.

## Pros and Cons of the Options

### pnpm

* Good, because lifecycle scripts are blocked by default.
* Good, because `minimumReleaseAge` is a defence that no other package manager
  has by default.
* Good, because the layout prevents phantom dependencies.
* Good, because the store decreases the disk space.
* Bad, because it is one more tool. Corepack makes the installation small.

### npm

* Good, because it is installed with Node.js. It needs no other tool.
* Good, because recent versions ask permission before they execute a script. We
  saw this behaviour during the agentOS test on 2026-08-23.
* Bad, because it has no equivalent of `minimumReleaseAge`.
* Bad, because the layout of `node_modules` is flat. A phantom dependency can
  occur.

### Yarn

* Good, because Plug'n'Play removes `node_modules` and gives strict resolution.
* Good, because the zero-installs method can put the dependencies in the
  repository.
* Bad, because Plug'n'Play is not compatible with some packages. agentOS is
  large and it is a preview version. This risk is not necessary.

### Bun

* Good, because the installation is very fast.
* Bad, because it is a different runtime. ADR 0002 selected Node.js, because
  agentOS is a Node.js library.

### Vendored dependencies, in the repository

* Good, because the dependencies cannot change without a commit.
* Bad, because the dependencies are 1.5 GB. The repository becomes unusable.

## More Information

This ADR does not change ADR 0002. ADR 0002 selected the language and it removed
the build step. This ADR selects the package manager. The rule in
`docs/adr/README.md` is that an accepted record does not change, thus this is a
new record.

The Rust CLI from ADR 0003 has a different supply chain. Cargo does not execute
a script from a dependency at installation time, but a `build.rs` file executes
during a build. Use the same discipline: put `Cargo.lock` in the repository, and
keep the number of dependencies small.

Examine this ADR again if pnpm changes these defaults, or if `allowBuilds`
becomes difficult to maintain.
