import Config

# The database is PostgreSQL (ADR 0028). A test run therefore needs a server
# running, which is exactly what ADR 0024 had bought and what ADR 0028 spent.
# ADR 0028 spent it for a self-hosted SuperTokens core; ADR 0029 moved the core
# to the managed service, and the state stayed in PostgreSQL, so the suite
# still needs a server. A fresh checkout needs one line first:
#
#     sudo systemctl start postgresql     # or: docker compose up -d db
#
# One database, always. `mix test --partitions N` looked like the obvious way
# to get N BEAMs running at once, and this file used to carry a
# MIX_TEST_PARTITION suffix for it. It is gone: ADR 0025 measured that option
# and found it does not divide the suite's work, because
# `Cucumber.compile_features!/1` runs unconditionally in test_helper.exs and
# generates every scenario as an ExUnit test regardless of which partition Mix
# thinks it is building — so N partitions run the whole Cucumber suite N times,
# not once between them. The suite runs as one process.
test_repo =
  [
    username: System.get_env("PGUSER") || "postgres",
    password: System.get_env("PGPASSWORD") || "postgres",
    hostname: System.get_env("PGHOST") || "127.0.0.1",
    port: String.to_integer(System.get_env("PGPORT") || "5432"),
    database: System.get_env("PGDATABASE") || "mealplan_test",
    pool: Ecto.Adapters.SQL.Sandbox,
    # A scenario holds one connection through a whole HTTP round trip, and the
    # endpoint answers on another process. The pool has to be wide enough for
    # both plus the checkout the sandbox owner holds.
    pool_size: 10
  ]
  |> then(fn opts ->
    case System.get_env("DATABASE_URL") do
      nil -> opts
      "" -> opts
      url -> Keyword.put(opts, :url, url)
    end
  end)

config :mealplan, Mealplan.Repo, test_repo

# The server IS run during test, and `config/runtime.exs` turns it on: the
# scenarios that walk the consent page and the /kroger screens drive it over
# loopback. That file also picks the port and matches the OAuth issuer to it.
config :mealplan, MealplanWeb.Endpoint,
  secret_key_base: "3wOsSBZcVA3BmHDWOFzU2zCimGsoke+zhZ4cZWmb7LGTEH3nDnTljYpHDot45MjO"

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# The SuperTokens core and the SMS provider are third-party HTTP APIs, so they
# are the one kind of thing this suite mocks (AGENTS.md). They are NOT set here:
# each scenario starts its own `Mealplan.Mock.Server` on a port the operating
# system picks, and puts the base into the application environment itself, the
# same way the Kroger and Walmart mocks do. `MEALPLAN_OWNER_PHONE` travels with
# them, from `Mealplan.Mock.SuperTokens`.

# ExUnit does not open the one household's corpus at application start. There is
# no one household under test: each scenario opens its own tenant over its own
# temporary folder, through `Mealplan.Boot.open_corpus/3`. Leaving the boot in
# would point a session at the developer's real meal plan, and on a machine with
# no sandbox image built it would refuse to start the application at all.
config :mealplan, boot_household: false

# The scenarios stay in features/, where AGENTS.md puts them and where the
# Cucumber suite read them from. Only the runner changed. Named one by one
# rather than globbed, so a new feature file has to be added here on purpose
# (ADR 0023) — the last one, sandbox.feature, landed with its own step
# definitions in test/features/step_definitions/sandbox_steps.exs. Its 51
# @security scenarios only assert something real under bubblewrap mode, so
# test_helper.exs excludes the :security tag rather than the file when
# MEALPLAN_SANDBOX=host has no image to test against.
config :cucumber,
  features: [
    "features/corpus.feature",
    "features/history.feature",
    "features/meals.feature",
    "features/migrations.feature",
    "features/pantry.feature",
    "features/preferences.feature",
    "features/recipes.feature",
    "features/sandbox.feature",
    "features/shopping_list.feature",
    "features/kroger_cart.feature",
    "features/kroger_link.feature",
    "features/auth.feature",
    "features/walmart.feature",
    "features/consumable_recheck.feature",
    "features/onboarding.feature",
    "features/sms_otp.feature"
  ],
  steps: ["test/features/step_definitions/**/*.exs"],
  support: ["test/features/support/**/*.exs"]
