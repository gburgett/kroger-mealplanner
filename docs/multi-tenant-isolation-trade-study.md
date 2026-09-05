# Trade study: which isolation model carries a tenant boundary

**Date:** 2026-08-26
**Status:** the §10 trigger *"More than one household, ever"* fired on
2026-09-05. [ADR 0027](adr/0027-give-the-session-layer-a-microvm.md) is written
from §9: microsandbox is now a selectable session-layer backend on this VM,
bubblewrap stays the default and the command layer. The rest of this study —
the cost model, the capacity numbers, the Fly Sprites threshold in §10 — still
stands and still decides nothing about the single-household lens.

Originally filed **open**: no ADR was written from this study, because no
decision was being taken. Multi-tenancy was a research question, not a
requirement — that is what [ADR 0008](adr/0008-use-bubblewrap-for-the-sandbox.md)
settled. This study answered "if it became a requirement tomorrow, what would we
reach for, and what would it cost?"
**Supersedes:** §11 of [`sandbox-trade-study.md`](sandbox-trade-study.md), which
asked the same question three days ago against a different candidate set and
without any cost model.
**Decides nothing about:** the single-household lens. Bubblewrap stays. See §9.

## 1. Why redo it

§11 of the earlier study concluded "plan for gVisor or Firecracker at the session
layer" and left it there. That is a shape, not a choice, and it carries no price.
Five specific candidates are now on the table:

1. RivetOS / agentOS — V8 isolates and WebAssembly, self-hosted or Rivet Cloud
2. E2B — Firecracker microVMs, SaaS
3. microsandbox — libkrun microVMs, self-hosted
4. Fly Sprites — persistent Firecracker microVMs, SaaS
5. Cloudflare Dynamic Workers — V8 isolates, SaaS

Four of the five have been looked at before and none was priced. agentOS and
microsandbox were measured in [`agent-runtime-spike.md`](agent-runtime-spike.md).
E2B and Fly Sprites were named in §4G of the earlier study and dismissed in three
lines — "they put a household's recipe folder on someone else's infrastructure" —
which is a correct single-household argument and an irrelevant multi-tenant one,
because R7 retires. Only Cloudflare Dynamic Workers is new to the analysis.

So this is not a fresh survey. It is the same candidates, re-scored against the
requirements that actually apply under the second lens, with money and measured
round trips attached. The stated preference is to keep everything on this VM and
to offload only if offloading is genuinely better. This study takes that
preference seriously and then tries to break it.

## 2. Requirements, under the multi-tenant lens

The single-household requirements R1–R8 are in §1 of the earlier study. Four of
them change when the lens changes, and the changes are what the candidates are
scored against.

| # | Requirement | Change from single-household |
| --- | --- | --- |
| R1 | Real `bash`, coreutils, `grep`, `find`, `sed`, `git` | **unchanged, and now the sharpest filter.** "MCP is a sandboxed shell" is the product. A runtime without a real shell is not a candidate, it is a different product. |
| R2 | One folder per tenant, read-write, persistent across calls and restarts | **unchanged in substance, harder to buy.** Most sandboxes are ephemeral by default. |
| R3 | No network at all, including DNS | unchanged |
| R4 | Nothing outside the mount reachable | **promoted.** Outside the mount now includes *every other tenant*. |
| R5 | Timeouts and output truncation | unchanged |
| R6 | Low per-command latency | **reshaped.** A session start amortises over ~30 commands; a per-command network round trip does not. |
| R7 | Files owned by the household user, folder is a real folder | **retired.** Nobody opens a tenant's folder in an editor. This is the requirement that made hosted options inadmissible before, and it is gone. |
| R8 | Cheap for one household on one VM | **replaced by R8′:** cheap *per idle tenant*, because almost every tenant is idle almost all the time. |
| R9 | — | **new: the tenant boundary must survive hostile code**, not just prompt injection. See §3. |
| R10 | — | **new: the corpus must stay POSIX.** Every scenario in `corpus.feature` assumes `sed -i`, `mv` and `git` behave normally. |

R7's retirement is what reopens this question at all. R9 and R10 are what close
most of it again.

## 3. Threat model

Restated from §11.1 of the earlier study, because it is the input that decides
everything else.

Single-tenant, the adversary is prompt injection carried in recipe text, and a
shared kernel is acceptable because reaching it means talking an agent into
writing a kernel exploit with no network to fetch one.

Multi-tenant, the adversary is **a paying customer who uploads a "recipe"
containing an exploit and has unlimited attempts.** That is hostile code
execution, which is precisely what namespaces are known not to contain. The
worst case stops being one family's inconvenience and becomes tenant A reading
tenant B's data.

The consequence is blunt: **a shared-kernel option cannot carry the session
layer.** That rules out containers, and it rules out bubblewrap-with-a-folder-
per-tenant, which ADR 0008 already refused to call multi-tenant. It does not rule
out bubblewrap *inside* a stronger boundary, which is the two-layer model in
§11.6 of the earlier study and is still the right shape.

## 4. Measured on this VM, 2026-08-26

Host: 2 vCPU, 3.9 GB RAM (1.9 GB available), 11 GB free disk, kernel 6.12.93,
near Cloudflare's EWR edge.

**The incumbent, re-measured.** 30 sequential `ls recipes/` through the real
bubblewrap command line from `src/sandbox/bubblewrap.ts`, against the built
image:

```
bwrap:           6.6 ms per command   (199 ms for 30)
no sandbox:      0.8 ms per command
```

ADR 0008 records 3.3 ms. The difference is load, not regression — this run
included the shell's own `fork`, and the VM had 2 GB in use. Take 6.6 ms as the
pessimistic figure and 3.3 ms as the quiet-machine one. Either way it is the
number every other option is compared against.

**Network round trip, warm keep-alive connection, from this VM.** Six sequential
requests on one TLS connection; the first carries the handshake and is discarded.

| Provider front door | Handshake | Warm round trip |
| --- | --- | --- |
| `api.sprites.dev` (Fly) | 41 ms | **~8 ms** |
| `api.cloudflare.com` | 34 ms | **~8 ms** |
| `rivet.dev` | 134 ms | **~86 ms** |
| `api.e2b.dev` | 135 ms | **~70–100 ms**, one sample at 282 ms |

**This measures the API front door returning a 404, not a command executing.** It
is a *floor* on per-command latency for an offloaded sandbox, not a measurement
of it. The real figure is this plus the hop to the region holding the tenant plus
the exec itself. It is still decisive, because a floor of 86 ms already costs
2.6 s of pure network on a thirty-command plan, and a floor of 8 ms does not.

**KVM.** `/dev/kvm` is `root:kvm` 0660, and `getent group kvm` shows `exedev` is
a member — but the current login predates the change, so `id` does not carry it
and `open("/dev/kvm")` gives `EACCES`. A fresh login or `newgrp kvm` fixes it.
microsandbox 0.6.14 is already installed. **The on-VM microVM option is one
logout away from being available**, which is worth knowing before costing
anything else.

**agentOS has not moved.** `npm view @rivet-dev/agentos version` is still
`0.2.15`, with `0.2.16-rc.2` on the `rc` tag — identical to what
[`agent-runtime-spike.md`](agent-runtime-spike.md) measured on 2026-08-23. The
six defects recorded there stand unamended. No re-spike was run, because nothing
shipped to re-spike.

## 5. The candidates

### A. RivetOS / agentOS (self-hosted, and Rivet Cloud)

V8 isolates plus WebAssembly, a trusted sidecar owning the guest kernel, a
package registry, a virtual filesystem that can mount S3 or a host directory.
Apache 2.0, self-hostable, with Rivet Cloud as the managed option. The vendor
claims 4.8 ms p50 cold start, ~22 MB per instance and "254× cheaper to run".

**Measured here on 2026-08-23: `git` does not execute.** `/opt/agentos/bin/git`
is a real 663 KB WebAssembly module; running it gives `Permission denied` on
0.2.15 and hangs without end on 0.2.16-rc.2. `grep` is absent — the registry
package supplies only `egrep` and `fgrep`. A three-stage pipeline gives
`Bad address`. A bare `ls` gives `Invalid argument`. Boot was 127 ms, not 5 ms,
and the process held 112 MB, not 22 MB.

**Fails R1.** Not on argument — on measurement, repeated, three days ago, against
a version that has not changed since. The vendor's own npm description for
`@agentos-software/git` still reads *"git version control for secure-exec VMs
(planned)"*.

This is the candidate I most want to be wrong about. Its economics are aimed
exactly at R8′, its VFS answers R2 in the one way that would make per-tenant
object storage pleasant rather than painful, and §11.4 of the earlier study said
in writing that under this lens it would be the recommendation. That statement is
honoured by re-checking the version, and the version is the same.

### B. E2B

Firecracker microVMs, SaaS, the most mature option in the set. Real Linux, real
`bash`, real `git`. Pause and resume preserve the filesystem *and* memory for up
to 30 days; pausing costs ~4 s per GiB of RAM, resuming ~1 s. A
filesystem-only snapshot (`keepMemory: false`) is lighter and cold-boots.

Passes R1–R6 and R9. Two problems: **$150/month before a single sandbox runs**
on the Pro plan, and a measured ~85 ms round trip from this VM.

### C. microsandbox

libkrun microVMs, self-hosted, Apache 2.0, pre-1.0. Already measured in
`agent-runtime-spike.md`: every functional test passes, 823 ms to open a session,
33 ms per command, 78 MB per tenant, needs KVM. `create` / `exec` / `rm` is a
true session, which is exactly the `open` / `run` / `close` seam the design
already carries.

**This is the only candidate that satisfies both R9 and the stated preference to
stay on this VM.** ADR 0008 rejected it, but read what it rejected it *for*:
"823 ms and 78 MB for each tenant buy a property one household does not need."
That reasoning is entirely single-household. Under this lens the property is the
requirement.

Its cloud offering is in closed beta with no published pricing, which does not
matter — the self-hosted runtime is the interesting part.

### D. Fly Sprites

Persistent Firecracker microVMs with 100 GB sparse NVMe, launched January 2026.
Checkpoint and restore is a first-class primitive at under a second. A sprite
sleeps after 30 seconds of inactivity and **is not billed while asleep** — only
its storage, at $0.02/GB-month cold. Files and installed packages survive across
sessions.

That last property is the one worth pausing on. Every other hosted sandbox treats
the filesystem as scratch and makes you rebuild it; Sprites treats it as the
durable thing and the compute as ephemeral. **That is the same claim as "the
folder is the database", made by the infrastructure instead of by us.**

Measured 8 ms to the front door from here, the best of the hosted set.

### E. Cloudflare Dynamic Workers

V8 isolates, a few milliseconds to start, a few megabytes of memory, no
concurrency limit, $0.002 per unique Worker loaded per day and waived during
beta. On the numbers it is the cheapest and fastest thing in this document by a
wide margin.

**It runs JavaScript.** Cloudflare's own announcement puts it plainly: "The only
catch, vs. containers, is that your agent needs to write JavaScript." The
filesystem is `@cloudflare/shell`, a library backed by SQLite and R2 — a shell
*emulation*, not GNU coreutils, and not `git`.

**Fails R1 and R10 by construction, and the failure is not fixable.** An MCP
server whose entire interface is "an assistant explores a folder the way a
developer explores a repository" cannot be built on a runtime with no `grep`, no
`sed -i` and no `git`. This is not a close call, and no price makes it one.

For completeness: **Cloudflare Sandbox SDK** is the Cloudflare product that does
run real `bash` and `git`, and it is priced very cheaply ($0.072/vCPU-h active,
$0.009/GiB-h, plus $5/month Workers Paid). But it is a *container* — shared
kernel — so it fails R9, the requirement that started this study. It would be a
network round trip added to the isolation class we already have locally for
6.6 ms. Strictly worse than the incumbent.

### Incumbent: bubblewrap

6.6 ms, zero cost, zero idle footprint, and **no tenant boundary at all.** ADR
0008 says so in its own consequences: every command runs as host uid 1000,
`nsenter` is refused so there is no session, and a folder per tenant is
"isolation, not containment". Carried here as the baseline, not as a candidate
for the session layer.

## 6. Comparison

| | bubblewrap | agentOS | E2B | microsandbox | Fly Sprites | CF Dynamic Workers |
| --- | --- | --- | --- | --- | --- | --- |
| Isolation class | namespaces | V8 + WASM | Firecracker | libkrun | Firecracker | V8 isolate |
| Carries R9 (hostile code) | **no** | no (shared sidecar) | **yes** | **yes** | **yes** | no |
| R1 real `bash`/`git` | yes | **no, measured** | yes | yes | yes | **no** |
| R10 POSIX corpus | yes, it is the folder | VFS adapter | yes | yes, host mount | yes, NVMe | **no** |
| Runs on this VM | yes | yes | no | **yes** | no | no |
| Session concept | thin, rebuilt each run | yes | pause/resume | `create`/`exec`/`rm` | checkpoint/restore | per-load |
| Time to first command | n/a | 127 ms measured | ~1 s resume | 823 ms measured | ~1 s restore | few ms |
| Per command | **6.6 ms measured** | 10–30 ms | ≥85 ms network floor | 33 ms measured | ≥8 ms network floor | few ms |
| Idle cost per tenant | zero | 112 MB measured | snapshot storage | zero if torn down | **$0.001/mo storage** | zero |
| External $/mo floor | **$0** | $0 self-host / $20 cloud | **$150** | **$0** | $20 | $5 |
| Maturity | Flatpak-grade | 0.2.15, API "subject to change" | mature | pre-1.0 | launched Jan 2026 | open beta |

## 7. Cost

### Assumptions, stated so they can be argued with

A household plans a week once a week: about 30 commands, plus browsing. Call it
**four sessions a month, ten minutes awake each — 0.67 awake-hours per month**,
against 730 hours in the month. That is a **0.09% duty cycle**, and it is the
single most important number in this section. Resources: 1 vCPU, 1 GiB. Corpus
with git history: 50 MB.

If that duty cycle is wrong the conclusions move. It is the assumption to attack
first.

### Per household-month, at the vendor's published rates

| Option | Compute | Storage | Per household-month |
| --- | --- | --- | --- |
| **Fly Sprites** | 0.67 h × ($0.07 CPU + $0.04375 GB) | 0.05 GB × $0.02 | **$0.077** |
| **E2B** | 0.67 h × ($0.0504 + $0.0162) | within free allowance | **$0.045** |
| Rivet Cloud | 0.67 h × ($0.119 + $0.010) | $0.40/GB-mo × 0.05 | $0.106 *(but R1 fails)* |
| CF Sandbox SDK | 0.67 h × $0.009 mem + active CPU | ephemeral | ~$0.01 *(but R9 fails)* |
| CF Dynamic Workers | $0.002/day | R2 | $0.06 *(but R1 fails)* |
| **microsandbox on this VM** | shares the VM | shares the VM | **$0.00 marginal** |
| **bubblewrap on this VM** | shares the VM | shares the VM | **$0.00 marginal** |

Fly's CPU carries a 6.25% minimum-utilisation floor rather than billing a whole
CPU while awake, so $0.077 is the pessimistic figure; a mostly-idle awake sprite
is nearer $0.032.

### Monthly total, including plan floors

Plan tiers are sold by **concurrent** sandboxes, not by tenant count, so the duty
cycle decides which tier is needed. Mean concurrency is 0.00092 N; allowing three
standard deviations of Poisson headroom gives the p99 figure below. The tiers turn
out to be far smaller than tenant count suggests, and that is the whole finding.

| Households | Concurrent (p99) | Fly Sprites | E2B |
| --- | --- | --- | --- |
| 1 | 1 | $20 Adventurer | $0, free tier |
| 100 | 3 | $20 + $8 = **$28** | $0–$150 + $5 |
| 1,000 | 5 | $20 + $77 = **$97** | $150 + $45 = **$195** |
| 10,000 | 18 | $50 Veteran + $770 = **$820** | $150 + $450 = **$600** |

Both vendors' smallest self-service tier — Fly's 20 concurrent sprites at $20,
E2B's 100 concurrent on Pro — carries four digits of households at this duty
cycle. E2B's free tier of 100 hours a month covers roughly 150 households before
the $150 fee starts, though its concurrency and session-length limits bite first.
E2B's curve is dominated by a flat fee a prototype pays in full on day one; Fly's
tracks actual usage from $20.

**Neither is expensive.** At 1,000 households both are under $200 a month, which
is noise against the inference bill for the same 1,000 households. Cost is not
what decides this, and the rest of this study stops treating it as though it
might.

## 8. Performance

Per week-plan: one session open plus thirty commands.

| Option | Session | 30 commands | Total per plan |
| --- | --- | --- | --- |
| **bubblewrap** | none | 30 × 6.6 ms | **0.2 s** |
| Fly Sprites | ~1.0 s restore | 30 × ≥8 ms + exec | **~1.6 s** |
| microsandbox | 0.82 s | 30 × 33 ms | **1.8 s** |
| E2B | ~1.0 s resume | 30 × ≥85 ms + exec | **~3.6 s** |
| agentOS | 0.13 s | — | *does not complete* |

The hosted rows are floors built from front-door round trips, not end-to-end
measurements. Read them as "no better than", never as "is".

Two things fall out. **Fly Sprites and microsandbox are within 200 ms of each
other** — the network advantage of being local is almost exactly cancelled by
microsandbox's slower session start. And **every microVM option costs roughly 1.5
seconds per plan against bubblewrap's 0.2**, which is a real regression a person
would notice once, at the start of a planning session, and then not again.

### The capacity question, which is the surprising one

microsandbox holds 78 MB per tenant. This VM has 1.9 GB available, so **about 24
concurrent tenants** before RAM runs out. That sounds like a small number until
it is set against the 0.09% duty cycle: mean concurrency for N households is
0.00092 N, and allowing three standard deviations of Poisson headroom, 24
concurrent supports roughly **N ≈ 13,000 households.**

That arithmetic is real but it is not a promise, for three reasons worth writing
down rather than discovering:

- **CPU, not RAM, is the likely ceiling, and it is unmeasured.** Two vCPUs also
  run the MCP server, Node, and a git commit after every mutating command. No
  throughput test has been run. Do not quote 13,000 to anybody.
- **Concurrency inside one tenant is a known open defect.** §11.7 of the earlier
  study records it and it has not been fixed: two commands against one folder
  race on `index.lock`, and a burst of parallel MCP tool calls did not all come
  back — the run stopped at the harness timeout rather than at an assertion.
  Whatever holds them is above the sandbox and remains unmeasured. Two scenarios
  for it were written during ADR 0008's implementation and then removed. **Nobody
  can cost the multi-tenant lens honestly until those are back and passing.**
- **One VM is one failure domain.** Thirteen thousand households behind a single
  `systemctl --user restart` is not a capacity problem, it is an availability
  one.

## 9. Recommendation

**Stay on this VM. Nothing in this study justifies offloading yet, and the reason
is capacity arithmetic, not preference.**

Concretely:

1. **The command layer does not change.** Bubblewrap, 6.6 ms, already built,
   already passing the `@security` scenarios. Every candidate here sits *above*
   it, never instead of it.

2. **When tenancy becomes real, the session layer is microsandbox, on this VM.**
   It is the only option that carries R9 and stays local. It is installed. KVM
   needs one fresh login. `create` / `exec` / `rm` drops onto the
   `open` / `run` / `close` seam ADR 0008 deliberately kept thin, which is that
   decision paying for itself. ADR 0005 already chose it once; ADR 0008 unchose
   it for reasons that are explicitly single-household and do not survive this
   lens.

3. **Fly Sprites is the offload target, and only when a named threshold is
   crossed.** It is the best hosted option in the set on every axis that matters
   here: a real kernel boundary, a genuinely persistent filesystem rather than
   scratch space, sub-second checkpoint restore, ~8 ms from this VM, and near-zero
   idle cost. Its persistence model is the closest thing on the market to this
   product's own premise. The thresholds are in §10.

4. **E2B is the fallback if Sprites disappoints**, at a worse round trip and a
   $150/month floor, bought in exchange for being the mature option.

5. **agentOS is out on measurement, not argument, and the door stays open.**
   Re-run the spike when a release ships in which `git` executes. Until then it
   fails the one requirement that is the product.

6. **Cloudflare Dynamic Workers are out permanently.** A JavaScript isolate
   cannot host a product whose interface is a POSIX shell. Cloudflare's container
   Sandbox SDK could, but it is a shared kernel behind a network hop — worse than
   what runs here today.

**The finding that generalises beyond dinner**, which is what this playground is
for: for a workload of mostly-idle tenants, *per-tenant isolation is far cheaper
than it looks, and the reason to leave your own machine is almost never cost or
capacity.* The duty cycle does the work. One small VM plausibly covers four
digits of households at $0 marginal, and the honest arguments for offloading are
the failure domain, the operational burden, and not wanting to run a KVM
scheduler — none of which appear in any vendor's pricing table.

## 10. What would change this decision

| If this becomes true | Do this |
| --- | --- |
| More than one household, ever | Give the session layer a microVM. Write the ADR. Bubblewrap alone is not a tenant boundary and ADR 0008 says so. |
| Sustained concurrency above ~15 tenants, or CPU saturation on 2 vCPU | Offload the session layer to Fly Sprites. |
| Availability becomes a commitment rather than a hope | Offload, regardless of capacity. One VM is one failure domain. |
| Tenants need the network inside the sandbox (Kroger from inside) | Re-open everything. Egress policy becomes the deciding axis and the local options get much worse. |
| A release of agentOS ships in which `git` executes | Re-run the spike from `agent-runtime-spike.md`. Its economics remain the best in the set. |
| The corpus has to leave local disk | Run `corpus.feature` and `history.feature` unchanged against the remote backend **before** choosing anything. That suite is the decisive experiment and it is already written. |
| microsandbox reaches 1.0 | Lower the risk weighting on §5.C; pre-1.0 is currently its main mark against. |

## 11. Open questions this study could not close

- **The concurrency defect in §8 blocks every number here.** It is the first thing
  to fix and it needs its two removed scenarios back.
- **No end-to-end latency was measured against any hosted provider.** The 8 ms
  and 85 ms figures are front-door floors. A one-afternoon spike — open a sprite,
  run thirty commands, time it — would replace a floor with a fact, and it is the
  cheapest high-value measurement left.
- **CPU throughput on 2 vCPU is unmeasured**, so §8's capacity ceiling is a RAM
  bound standing in for a CPU bound.
- **Does the folder survive not being local?** Unchanged from §11.7 of the earlier
  study, and unanswered. `sed -i`, `mv` and `git` on a non-POSIX backend is the
  experiment.
- **exe.dev VM pricing was not obtained**, so "$0 marginal" means marginal against
  a VM already being paid for, not free.

## 12. Sources

Measured on this VM 2026-08-26 (§4) and 2026-08-23 (`agent-runtime-spike.md`,
`bubblewrap-lockdown-study.md`); everything else:

- [agentOS — Rivet](https://rivet.dev/agent-os/)
- [rivet-dev/agentos on GitHub](https://github.com/rivet-dev/agentos)
- [Rivet Cloud pricing](https://rivet.dev/pricing/)
- [E2B workload pricing estimator](https://pricing.e2b.dev/)
- [E2B sandbox persistence](https://e2b.dev/docs/sandbox/persistence)
- [Sprites: full Linux computers for your agents — Fly](https://fly.io/sprites/)
- [More Sprites Plans! — Fly community](https://community.fly.io/t/more-sprites-plans/26857)
- [Sandboxing AI agents, 100x faster — Cloudflare](https://blog.cloudflare.com/dynamic-workers/)
- [Cloudflare Sandbox SDK pricing](https://developers.cloudflare.com/sandbox/platform/pricing/)
- [AI sandbox pricing comparison 2026 — Northflank](https://northflank.com/blog/ai-sandbox-pricing)
- [Microsandbox — Ry Walker Research](https://rywalker.com/research/microsandbox)
