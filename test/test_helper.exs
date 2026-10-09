# `max_cases: 1` runs one test at a time. The database is one SQLite file that
# takes one writer at a time, and the scenarios share one endpoint and one set
# of mock listeners.
ExUnit.start(max_cases: 1)
Ecto.Adapters.SQL.Sandbox.mode(Mealplan.Repo, :manual)

# `mix test` ends the BEAM with `System.halt/1`, which does not run application
# stop callbacks, so `Mealplan.Application.stop/1` never fires here and the
# run's scratch root would be left behind empty. Collected at the next start by
# `sweep_stale/0` because its pid is gone — but a run that cleans up after
# itself is worth the two lines.
ExUnit.after_suite(fn _ ->
  Mealplan.Store.Scratch.release()
  :ok
end)

# `@future` scenarios document intent that is not built yet (features/README.md).
# They never run. There is no sandbox mode to choose between any more
# (ADR 0039): every @security scenario runs in every run, because the boundary
# it asserts — a path cannot leave the household, a token reaches only its own
# tenant — is authorisation, and nothing in the environment weakens it.
ExUnit.configure(exclude: [:future])

# The scenarios under features/ are the specification (AGENTS.md), and they run
# here, in this process, against the real tool handlers. `compile_features!`
# turns each one into an ExUnit test.
Cucumber.compile_features!()
