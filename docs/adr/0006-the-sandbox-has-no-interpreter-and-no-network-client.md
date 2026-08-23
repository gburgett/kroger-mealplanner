---
status: accepted
date: 2026-08-23
decision-makers: gburgett
consulted: agent runtime spike (docs/agent-runtime-spike.md)
informed: all contributors
---

# The sandbox has no interpreter and no network client

## Context and Problem Statement

The sandbox root filesystem is ours to build. ADR 0005 boots each tenant from a root
filesystem we make. Every program in that image is a program the agent can run.

The agent is not trusted. A recipe is text, and text arrives from the person and from
the web. Prompt injection in recipe text can make the agent run any command the image
supplies.

ADR 0005 refuses the network with a configuration file. A configuration file is one
line, and one line can be wrong. The spike found that microsandbox allows the network
by default, so the configuration is the only thing between the agent and the internet.

Which programs must the image contain?

## Decision Drivers

* The agent must not reach the network. This is `@security` in
  `features/sandbox.feature` and `features/history.feature`.
* The agent must not run arbitrary code. A shell command is a bounded thing. A Python
  program is not.
* A containment control must not depend on one setting being correct.
* The specifications must fail for the correct reason. A scenario that passes because
  a program is absent, when it claims to prove the network is refused, is a scenario
  that lies.

## Considered Options

* Put only the programs the specifications need in the image
* Use a full distribution image and refuse the network with configuration only
* Use a full distribution image and remove the dangerous programs after the build

## Decision Outcome

Chosen option: "Put only the programs the specifications need in the image", because
containment then does not depend on one setting.

The image contains: `bash`, coreutils, `grep`, `sed`, `gawk`, `findutils`, `diffutils`,
`git`, and the `mealplan` command from ADR 0007.

The image does not contain: `python3`, `node`, `perl`, `ruby`, `curl`, `wget`, `nc`,
`ssh`, `getent`, or any other interpreter or network client.

The network is also refused in the microsandbox network configuration. The two
controls are independent. Neither one is the only control.

### Consequences

* Good, because two independent controls refuse the network. A wrong line in the
  network configuration does not open the sandbox, because no program in the image can
  use a socket.
* Good, because the image is small. The spike measured 24 MB for Alpine with `git` and
  `grep`.
* Good, because it agrees with the rule in `AGENTS.md`: "Prefer bash over new tools."
  A program enters the image only when a scenario needs it.
* Bad, because `git push` is the one command that can still try to reach the network.
  This is correct and wanted. `git` must be in the image, and the `@security` scenario
  "History cannot be pushed anywhere" is then a true test of the network
  configuration, not a test of an absent program.
* Bad, because scenarios that name `python3`, `curl`, `wget`, `nc` and `getent` must
  change. They are in `features/sandbox.feature`. Each one must move to `@security`
  and assert that the command **cannot be used**, and must not assert that the network
  is refused. A "command not found" does not prove containment.
* Bad, because "A command that eats all the memory is stopped" drives the memory
  through `python3`. It must be rewritten against a program the image supplies.
* Neutral, because a future feature may need a program. Add it to the image, and say
  in this record's successor why the risk is acceptable.

### Confirmation

1. A `@security` scenario for each removed program. It must assert the command cannot
   be used. `python3`, `curl`, `wget`, `nc` and `getent`.
2. The `@security` scenario "History cannot be pushed anywhere" must fail with a
   network error, not with "command not found". This is the scenario that proves the
   network configuration of ADR 0005.
3. Two scenarios must be rewritten because a microVM has its own root filesystem:
   `cat /etc/passwd` and `cat /proc/1/environ` succeed and read the guest. They must
   assert that nothing of the **host** is reachable, which is the property that
   matters.
4. A list of the programs in the image must be in the repository, and a scenario must
   compare the image against that list. An image that grows without a record is the
   way this decision is lost.

## More Information

`docs/agent-runtime-spike.md`, Part 3, records that microsandbox allows the network by
default, and records what `cat /etc/passwd` and `cat /proc/1/environ` do in a microVM.
