import Config

# The database is one SQLite file (ADR 0024, restored by ADR 0030), so a test
# run needs NOTHING running: no server, no user, no password, no port. That is
# the whole reason the adapter went back — ADR 0028 had made `mix test` in a
# fresh checkout fail on a PostgreSQL server that was not up, which said nothing
# about the code under test, and ADR 0029 removed the reason that server was
# there.
#
# One file, always. `mix test --partitions N` looked like the obvious way to
# get N BEAMs running at once, and this file used to carry a MIX_TEST_PARTITION
# suffix for it. It is gone: ADR 0025 measured that option and found it does
# not divide the suite's work, because `Cucumber.compile_features!/1` runs
# unconditionally in test_helper.exs and generates every scenario as an ExUnit
# test regardless of which partition Mix thinks it is building — so N
# partitions run the whole Cucumber suite N times, not once between them. The
# suite runs as one process. The file is created by `ecto.create` and left
# behind between runs; `mix ecto.reset` or `rm mealplan_test.db` clears it.
config :mealplan, Mealplan.Repo,
  database: Path.expand("../mealplan_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5,
  # A scenario holds one connection through a whole HTTP round trip, and the
  # endpoint answers on another process. Five seconds of waiting for the write
  # lock is generous next to that, and it turns a lost race into a wait rather
  # than a "database is busy" that reads like a product bug.
  busy_timeout: 5_000,
  # Readers do not block the writer. The scenarios drive the endpoint while
  # holding the sandbox connection, which is exactly the shape WAL is for.
  journal_mode: :wal

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
    "features/family_size.feature",
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
    "features/invitations.feature",
    "features/walmart.feature",
    "features/consumable_recheck.feature",
    "features/onboarding.feature",
    "features/sms_otp.feature"
  ],
  steps: ["test/features/step_definitions/**/*.exs"],
  support: ["test/features/support/**/*.exs"]
