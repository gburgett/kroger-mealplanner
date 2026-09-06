# `max_cases: 1` runs one test at a time. The default is one per scheduler,
# and each scenario copies a git repository, spawns a `bwrap` (or a host
# command) and runs the `mealplan` binary — four of those at once is a real
# memory spike, and this VM has 3.9 GB and a small swapfile. The suite takes
# longer this way; run time is not the constraint here, headroom is.
ExUnit.start(max_cases: 1)
Ecto.Adapters.SQL.Sandbox.mode(Mealplan.Repo, :manual)

# `mix test` ends the BEAM with `System.halt/1`, which does not run application
# stop callbacks, so `Mealplan.Application.stop/1` never fires here and the
# run's scratch root would be left behind empty. One directory, collected at the
# next start by `sweep_stale/0` because its pid is gone — but a run that cleans
# up after itself is worth the two lines, and it keeps a developer's /tmp free
# of a directory per interrupted run.
ExUnit.after_suite(fn _ ->
  Mealplan.Sandbox.Scratch.release()
  :ok
end)

# The scenarios under features/ are the specification (AGENTS.md), and they run
# here, in this process, against the real tool handlers. `compile_features!`
# turns each one into an ExUnit test.
#
# Which scenarios and unit tests this run can honestly assert depends on the
# backend:
#
#   * host — there is no sandbox, so every @security scenario would pass or fail
#     for the wrong reason. Exclude them, loudly (ADR 0022). The @microsandbox
#     tag never matches here either.
#   * microsandbox — most @security scenarios hold against a microVM, but the
#     ones tagged @bubblewrap assert a bubblewrap mechanism (a seccomp EPERM, an
#     absent /etc) that a microVM meets by a different route or not at all; each
#     has a @microsandbox companion. The @fork-limit scenario is an accepted
#     downgrade (ADR 0027).
#   * bubblewrap — the @microsandbox scenarios and the microsandbox unit tests
#     need real libkrun, so they are excluded.
# `@future` scenarios document intent that is not built yet (features/README.md).
# They never run in any mode.
excludes =
  [:future] ++
    cond do
      not Mealplan.Sandbox.confined?() -> [:security, :microsandbox]
      Mealplan.Sandbox.mode() == :microsandbox -> [:bubblewrap, :"fork-limit"]
      true -> [:microsandbox]
    end

ExUnit.configure(exclude: excludes)

unless Mealplan.Sandbox.confined?() do
  IO.puts(:stderr, """

  ┌───────────────────────────────────────────────────────────────────────────┐
  │ MEALPLAN_SANDBOX=host — commands run UNCONFINED, and the @security        │
  │ scenarios are NOT running. This run says nothing about containment.       │
  │ Before a release, run them for real:                                      │
  │     ./sandbox-image/build.sh && ./cli/build.sh && mix test                │
  └───────────────────────────────────────────────────────────────────────────┘
  """)
end

if Mealplan.Sandbox.mode() == :microsandbox do
  IO.puts(:stderr, """

  ┌───────────────────────────────────────────────────────────────────────────┐
  │ MEALPLAN_SANDBOX=microsandbox — each tenant runs in a libkrun microVM.    │
  │ @bubblewrap scenarios and @fork-limit are excluded (ADR 0027); their      │
  │ @microsandbox companions run instead.                                     │
  └───────────────────────────────────────────────────────────────────────────┘
  """)
end

Cucumber.compile_features!()
