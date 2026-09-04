ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Mealplan.Repo, :manual)

# The scenarios under features/ are the specification (AGENTS.md), and they run
# here, in this process, against the real tool handlers. `compile_features!`
# turns each one into an ExUnit test.
#
# Under MEALPLAN_SANDBOX=host there is no sandbox, so every @security scenario
# would assert something that is false and pass or fail for the wrong reason.
# They are excluded — loudly. A suite that reports green having quietly dropped
# the security scenarios is the one failure this mode must not have. See
# ADR 0022.
unless Mealplan.Sandbox.confined?() do
  ExUnit.configure(exclude: [:security])

  IO.puts(:stderr, """

  ┌───────────────────────────────────────────────────────────────────────────┐
  │ MEALPLAN_SANDBOX=host — commands run UNCONFINED, and the @security        │
  │ scenarios are NOT running. This run says nothing about containment.       │
  │ Before a release, run them for real:                                      │
  │     ./sandbox-image/build.sh && ./cli/build.sh && mix test                │
  └───────────────────────────────────────────────────────────────────────────┘
  """)
end

Cucumber.compile_features!()
