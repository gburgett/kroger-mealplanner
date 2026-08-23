---
status: accepted
date: 2026-08-23
decision-makers: gburgett
consulted: sandbox trade study (docs/sandbox-trade-study.md)
informed: all contributors
---

# Use agentOS for the sandbox

## Context and Problem Statement

The MCP server gives an agent shell access to a meal-plan folder. The agent runs
`ls`, `grep`, `find`, `cat` and `sed`. The agent also writes files. The sandbox
holds the agent. Thus the sandbox is the security boundary for the product.

This project has a second purpose. It is a test of how much control an agent can
have in an MCP server in a multi-tenant SaaS environment. The sandbox choice is
the primary test of that question.

Which technology must the sandbox use?

## Decision Drivers

* The sandbox must prevent all network access. This includes DNS.
* The sandbox must prevent all access outside the meal-plan folder.
* The sandbox must supply `bash`, coreutils, `grep`, `find`, `sed` and `git`.
* Each command must be fast. The agent runs approximately 30 commands to plan
  one week.
* The cost for each idle tenant must be low. A SaaS environment has many tenants
  that are idle.
* The installation must be simple. Root permission must not be necessary.
* The choice must help the project to examine multi-tenant SaaS patterns.

## Considered Options

* agentOS
* bubblewrap
* Docker container
* gVisor
* Firecracker microVM

## Decision Outcome

Chosen option: "agentOS", because it satisfies the security drivers, it has the
lowest cost for each tenant, and it installs as a library without root
permission. It is also the option that best matches the multi-tenant purpose of
the project.

The other options are correct for one household on one machine. agentOS is the
option that tests the question this project exists to answer.

### Consequences

* Good, because agentOS denies network access and file access by default. A
  permission is necessary before an agent can do these operations.
* Good, because the cost for each agent is low. The supplier states
  approximately 22 MB of memory and a cold start of approximately 5 ms.
* Good, because `npm install` is the only installation step. Root permission,
  a daemon and a kernel module are not necessary.
* Good, because agentOS can mount S3 storage and host directories. Object
  storage is the usual storage for a multi-tenant product.
* Good, because the package registry supplies `git` and `ripgrep`. The corpus
  design needs both.
* Good, because agentOS includes agent orchestration. The project can use this
  to test agent control patterns.
* Bad, because version 0.2.15 is a preview version. The supplier states that the
  API can change. The security boundary of the product is on a preview version.
* Bad, because `npm install` downloads 1.5 GB of dependencies. These include
  `googleapis` and the Anthropic SDK. This is a large supply chain.
* Bad, because agentOS operates only in Node.js. This makes the technology
  choice for the server before the specifications make it.
* Bad, because the filesystem is a virtual filesystem. POSIX operations such as
  `sed -i`, `mv` and `git` can behave differently than on a local disk.
* Bad, because the agentOS kernel is new software. gVisor has approximately ten
  more years of adversarial review.
* Neutral, because a change to a different sandbox stays possible. The session
  interface in "More Information" keeps the cost of a change low.

### Confirmation

The specifications confirm this decision. No other confirmation is necessary.

1. All 15 `@security` scenarios in `features/sandbox.feature` must pass. These
   scenarios test network access, access outside the mount, symbolic link
   escape and the leak of the server environment.
2. All scenarios in `features/corpus.feature` and `features/history.feature`
   must pass without a change. These scenarios test `git` and POSIX behaviour.
   A failure shows the cost of the virtual filesystem.
3. Measure the cold start time and the memory for each tenant. Compare the
   measurements with the values in this ADR.

If step 1 fails, this decision is not correct. Change to gVisor.
If step 2 fails, examine each failure. A small number of failures can be
acceptable. A failure of `git` is not acceptable.

## Pros and Cons of the Options

### agentOS

An operating system as a library. It uses V8 isolates and WebAssembly. A trusted
sidecar process owns the kernel of each virtual machine. Apache 2.0 licence.
Version 0.2.15.

* Good, because permissions are deny-by-default for the network, the filesystem
  and processes.
* Good, because the cost for each tenant is the lowest of all the options.
* Good, because installation needs no root permission and no daemon.
* Good, because it mounts S3 storage. This matches a multi-tenant product.
* Bad, because the version is a preview version.
* Bad, because the dependencies are 1.5 GB.
* Bad, because the filesystem is virtual, not a folder on a local disk.

### bubblewrap

Linux namespaces without root permission. Measured on this machine on
2026-08-23.

* Good, because a command takes 6 ms. This is the fastest measured option.
* Good, because 14 of the 15 `@security` scenarios pass.
* Good, because the meal-plan folder is a folder on a local disk. All POSIX
  operations and `git` operate correctly.
* Good, because bubblewrap is installed on this machine already.
* Bad, because the kernel is common to the host and the sandbox. A kernel
  vulnerability puts all tenants at risk.
* Bad, because bubblewrap has no limits for CPU, memory or processes.
* Bad, because `cat /proc/1/environ` showed 99 environment variables of the
  server process. A scrubbed environment corrects this.

### Docker container

Measured on this machine on 2026-08-23.

* Good, because limits for CPU, memory and processes are available.
* Good, because Docker is installed on this machine already.
* Bad, because a warm command takes 52 ms and a cold command takes 335 ms.
* Bad, because the container writes files that have `root` as the owner.
* Bad, because the kernel is common to the host and the sandbox.

### gVisor

A kernel in user space. It is the sandbox of Google Cloud Run and Modal.

* Good, because it decreases the attack surface of the host kernel.
* Good, because it has approximately ten years of adversarial review.
* Good, because it is the usual choice for multi-tenant code execution.
* Bad, because installation needs root permission.
* Bad, because I/O operations are 10% to 30% slower.

### Firecracker microVM

A virtual machine with a separate guest kernel. It is the sandbox of AWS Lambda,
E2B and Fly.io.

* Good, because the separation is at the hardware level. This is the strongest
  boundary.
* Bad, because a cold start takes 125 ms to 2 s.
* Bad, because the user `exedev` cannot read `/dev/kvm` on this machine. A
  change to the group permissions is necessary first.
* Bad, because the cost for each idle tenant is the highest of all the options.

## More Information

`docs/sandbox-trade-study.md` contains the measurements, the threat model and
the full comparison. Section 11 examines the multi-tenant conditions.

The sandbox interface must have a session. Do not use an interface that has only
commands:

```
session = open(tenant)
session.run(command)
session.close()
```

The trade study shows that production systems use two boundaries. The session
boundary holds the tenant. The command boundary is fast. A session in the
interface keeps this pattern possible. A change to add a session later is
expensive.

Examine this ADR again when one of these conditions is true:

* agentOS releases version 1.0.
* An `@security` scenario fails.
* The product has more than one tenant in production.
* The sandbox must have network access for Kroger operations.
