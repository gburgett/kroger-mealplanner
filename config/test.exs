import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :mealplan, Mealplan.Repo,
  username: System.get_env("PGUSER", "exedev"),
  password: System.get_env("PGPASSWORD", "mealplan_dev"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: "mealplan_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :mealplan, MealplanWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "3wOsSBZcVA3BmHDWOFzU2zCimGsoke+zhZ4cZWmb7LGTEH3nDnTljYpHDot45MjO",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# ExUnit does not open the one household's corpus at application start. There is
# no one household under test: each scenario opens its own tenant over its own
# temporary folder, through `Mealplan.Boot.open_corpus/3`. Leaving the boot in
# would point a session at the developer's real meal plan, and on a machine with
# no sandbox image built it would refuse to start the application at all.
config :mealplan, boot_household: false

# The scenarios stay in features/, where AGENTS.md puts them and where the
# Cucumber suite read them from. Only the runner changed.
# Named one by one rather than globbed, because four feature files are NOT
# ported yet and a glob would report them as failures rather than as work:
#
#   auth.feature, kroger_link.feature, kroger_cart.feature, walmart.feature,
#   consumable_recheck.feature
#
# Those need the OAuth handshake and the three mocked third-party HTTP APIs,
# which the TypeScript harness stood up per scenario. Adding a file here is how
# they come back. See docs/test-suite-parallelisation-study.md §9.
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
    "features/shopping_list.feature"
  ],
  steps: ["test/features/step_definitions/**/*.exs"],
  support: ["test/features/support/**/*.exs"]
