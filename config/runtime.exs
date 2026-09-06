import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/mealplan start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :mealplan, MealplanWeb.Endpoint, server: true
end

mealplan_port =
  String.to_integer(System.get_env("MEALPLAN_PORT") || System.get_env("PORT", "4000"))

config :mealplan, MealplanWeb.Endpoint, http: [port: mealplan_port]

# --- MEALPLAN_* runtime configuration, for every environment ---------------
#
# Mirrors the environment variables `server.ts` reads. Runs for `mix release`
# too, so the systemd unit only has to set these.

get = fn key, default -> System.get_env(key) || default end

walmart_private_key =
  cond do
    key = System.get_env("WALMART_PRIVATE_KEY") -> key
    path = System.get_env("WALMART_PRIVATE_KEY_PATH") -> File.read!(path)
    true -> nil
  end

config :mealplan,
  # ADR 0033: no configured owner and no bootstrap household. Every household is
  # invited from the command line (`mix mealplan.invite`), and the first code
  # provisions its tenant and a fresh folder under MEALPLAN_CORPUS_ROOT.
  corpus_root: get.("MEALPLAN_CORPUS_ROOT", Path.expand("~/meal-plans")),
  # The old single-household folder. Kept defined only as a pointer for a
  # follow-up record that moves its contents into the re-onboarded tenant;
  # nothing reads it at runtime.
  folder: System.get_env("MEALPLAN_FOLDER"),
  port: mealplan_port,
  # The OAuth issuer and the address clients reach this server at. Never
  # derived from a Host header. Synthesised from the bind when unset, so local
  # development and a scenario's spawned release both have a usable value.
  public_url: System.get_env("MEALPLAN_PUBLIC_URL") || "http://127.0.0.1:#{mealplan_port}",
  kroger_client_id: get.("KROGER_CLIENT_ID", ""),
  kroger_client_secret: get.("KROGER_CLIENT_SECRET", ""),
  kroger_api_base: System.get_env("KROGER_API_BASE"),
  walmart_consumer_id: get.("WALMART_CONSUMER_ID", ""),
  walmart_private_key: walmart_private_key,
  walmart_api_base: System.get_env("WALMART_API_BASE"),
  walmart_cart_base: System.get_env("WALMART_CART_BASE"),
  walmart_key_version: get.("WALMART_KEY_VERSION", "1"),
  walmart_publisher_id: System.get_env("WALMART_PUBLISHER_ID"),
  llm_base: System.get_env("MEALPLAN_LLM_BASE"),
  # --- the household's sign-in (ADR 0027, ADR 0033) ---------------------
  #
  # There is no single owner telephone any more. `Mealplan.Auth.Otp.start/1`
  # admits a number when an `invitations` row names it, and refuses every other
  # one BEFORE the core is called, so a stranger costs no message.
  #
  # The SuperTokens core — the managed deployment (ADR 0029), reached over
  # HTTPS. `SUPERTOKENS_API_KEY` is the whole of the lock: the core is a
  # trusted component, anything that can call it can act on every user, and
  # there is no network boundary in front of it. A missing key is no sign-in
  # at all, and `Mealplan.Boot` says so in the start-up health line.
  supertokens_base:
    get.(
      "SUPERTOKENS_CONNECTION_URI",
      "https://st-dev-ff40b340-a989-11f1-abbd-07395602a114.aws.supertokens.io"
    ),
  supertokens_api_key: System.get_env("SUPERTOKENS_API_KEY"),
  # "twilio" or "telnyx". The core makes the code and hands it back; this
  # server posts it. Neither provider is a package — one signed call each,
  # through Req, the same as Kroger and Walmart.
  sms_provider: get.("MEALPLAN_SMS_PROVIDER", "twilio"),
  sms_from: System.get_env("MEALPLAN_SMS_FROM"),
  twilio_account_sid: System.get_env("TWILIO_ACCOUNT_SID"),
  twilio_auth_token: System.get_env("TWILIO_AUTH_TOKEN"),
  twilio_api_base: System.get_env("TWILIO_API_BASE"),
  telnyx_api_key: System.get_env("TELNYX_API_KEY"),
  telnyx_messaging_profile_id: System.get_env("TELNYX_MESSAGING_PROFILE_ID"),
  telnyx_api_base: System.get_env("TELNYX_API_BASE")

# MEALPLAN_SANDBOX picks the confinement. "bubblewrap" is the product and the
# default, test included; "host" runs commands unconfined and is for testing
# application logic where no sandbox image can be built, such as a CI runner —
# it reaps each command's process group itself, so it does not accumulate stray
# process trees (ADR 0034); "microsandbox" gives each tenant its own libkrun
# microVM (ADR 0027), for more than one household on one machine, and needs
# read/write on /dev/kvm. Anything else is a typo, and a typo that silently
# disabled the security boundary would be the worst possible failure, so it
# raises. See ADR 0022, ADR 0027, ADR 0034 and Mealplan.Sandbox.mode/0.
sandbox_mode =
  case System.get_env("MEALPLAN_SANDBOX") do
    nil -> :bubblewrap
    "" -> :bubblewrap
    "bubblewrap" -> :bubblewrap
    "host" -> :host
    "microsandbox" -> :microsandbox
    other ->
      raise "MEALPLAN_SANDBOX must be \"bubblewrap\", \"host\" or \"microsandbox\", got #{inspect(other)}"
  end

max_live_sessions =
  case System.get_env("MEALPLAN_MAX_LIVE_SESSIONS") do
    nil -> nil
    "" -> nil
    n -> String.to_integer(n)
  end

config :mealplan, Mealplan.Sandbox,
  mode: sandbox_mode,
  image_root: System.get_env("MEALPLAN_IMAGE_ROOT"),
  seccomp_filter: System.get_env("MEALPLAN_SECCOMP_FILTER"),
  # A .tar the microsandbox backend loads into `msb`, or a bare `msb` image
  # reference. Defaults to sandbox-image/oci.tar.
  microsandbox_image: System.get_env("MEALPLAN_MICROSANDBOX_IMAGE"),
  # nil here means "use the backend's own default" — 16 for microsandbox,
  # unbounded for bubblewrap/host. See Mealplan.Sandbox.max_live_sessions/0.
  max_live_sessions: max_live_sessions

# Where the sandbox puts a command's stream files and its TMPDIR, and where the
# scenarios put their corpora. `Mealplan.Sandbox.Scratch` explains the layout;
# this only picks the ground it sits on.
#
# MEALPLAN_TMPDIR wins wherever it is set. It is read here rather than in the
# module because the sweep of stale roots runs at application start, and a base
# chosen after that would leave the sweep looking in the wrong place.
if dir = System.get_env("MEALPLAN_TMPDIR") do
  config :mealplan, :tmp_base, dir
end

# Both test runners — `mix test` and the TypeScript harness that still runs
# features/sandbox.feature — get a tmpfs when the machine has one. Not only the
# ExUnit one: the 11 GB of `sort` spill was left by the TypeScript harness in
# host mode, which is the combination with no bounded /tmp of its own.
if config_env() == :test do
  # A test run is much happier on a tmpfs, and it is measurably faster: the
  # suite copies a git repository per scenario and 200 scenarios of that came
  # down from 56.4 s to 50.1 s on this VM, about 11%.
  #
  # It is also the safer ground. A tmpfs is bounded, so a command that runs
  # away — `yes | sort`, the memory-limit scenario — hits ENOSPC in RAM instead
  # of filling the disk the database and the corpora are on. That is not
  # hypothetical: it happened here, 11 GB of `sort` spill, the disk at 94%.
  #
  # Only when the machine actually has one with room to spare. Docker gives a
  # container 64 MB of /dev/shm by default and other processes share it, so the
  # check is for free space rather than for the mount, and anything short falls
  # back to the ordinary temporary directory. A run needs well under a
  # megabyte — the whole tree peaked at 508 KB — so 64 MB is a hundredfold
  # margin, chosen to fail towards the disk rather than towards ENOSPC.
  unless System.get_env("MEALPLAN_TMPDIR") do
    free_kb = fn dir ->
      with true <- File.dir?(dir),
           exe when is_binary(exe) <- System.find_executable("df"),
           {out, 0} <- System.cmd(exe, ["-Pk", dir], stderr_to_stdout: true),
           [_header, line | _] <- String.split(out, "\n"),
           [_fs, _blocks, _used, avail | _] <- String.split(line, ~r/\s+/) do
        String.to_integer(avail)
      else
        _ -> 0
      end
    end

    if free_kb.("/dev/shm") >= 64 * 1024 do
      config :mealplan, :tmp_base, "/dev/shm"
    end
  end
end

# The frozen clock. The Cucumber suite runs the release as its own OS process
# and cannot inject a `now` function, so it pins the instant through
# MEALPLAN_CLOCK (ISO 8601). `Mealplan.Clock` reads it back. Mirrors the
# `now: Clock` option the TypeScript `startServer` took.
if clock = System.get_env("MEALPLAN_CLOCK") do
  config :mealplan, :clock, clock
end

# Where the server state lives: one SQLite file (ADR 0024, restored by
# ADR 0030). MEALPLAN_STATE is the same variable the TypeScript server read for
# `auth.json`, and it keeps the same rule — the file must be OUTSIDE the
# meal-plan folder, because the sandbox mounts that folder and the agent reads
# every byte of it. Under PostgreSQL (ADR 0028) that was true by construction;
# with a file it is a check again, and `Mealplan.Boot` makes it, refusing to
# start rather than serving with the household's Kroger credential inside the
# agent's reach.
#
# Not in test. A developer who exports MEALPLAN_STATE for the dev server would
# otherwise have `mix test` open it, and the Ecto sandbox would roll the
# household's real clients and tokens back out from under the running server.
# The test database is named in config/test.exs.
if config_env() != :test do
  if state = System.get_env("MEALPLAN_STATE") do
    config :mealplan, Mealplan.Repo, database: state
  end
end

# The TypeScript harness (features/support/world.ts) is still the only runner for
# features/sandbox.feature, and it spawns this app as an OS process on a port it
# reserved itself. CUCUMBER=1 is how it says so: the port and the pool below are
# ITS choices, and the ExUnit block after this one must not overrule them.
if config_env() == :test and System.get_env("CUCUMBER") do
  config :mealplan, MealplanWeb.Endpoint, server: true

  # One of these servers runs at a time (ADR 0025 — the suite is not
  # partitioned across workers), against the one database file config/test.exs
  # names. The pool stays small anyway: a scenario drives one client through
  # one request at a time, and does not need ten connections to do it.
  config :mealplan, Mealplan.Repo,
    pool: DBConnection.ConnectionPool,
    pool_size: String.to_integer(System.get_env("MEALPLAN_POOL_SIZE") || "4"),
    busy_timeout: 5_000,
    journal_mode: :wal
end

# The scenarios run in this BEAM (ADR 0022), and the ones that walk the consent
# page and the /kroger screens need a server to walk it on. They drive it over
# loopback with a real HTTP client, so the exe.dev gate, the redirects and the
# form posts are all the real ones — which is how the authorisation server keeps
# the coverage the move in process would otherwise have cost it.
#
# The issuer must be the address the server actually answers on, because a
# redirect_uri is built from it and Kroger's callback comes back to it.
if config_env() == :test and is_nil(System.get_env("CUCUMBER")) do
  # A fixed port, not one derived from MIX_TEST_PARTITION: ADR 0025 rejected
  # partitioning, so there is only ever one of these to bind.
  test_port = String.to_integer(System.get_env("MEALPLAN_TEST_PORT") || "4002")

  config :mealplan, MealplanWeb.Endpoint,
    server: true,
    http: [ip: {127, 0, 0, 1}, port: test_port]

  config :mealplan, public_url: "http://127.0.0.1:#{test_port}"
end

if config_env() == :prod do
  # No URL, no user, no port: the whole database is a path (ADR 0024, restored
  # by ADR 0030). It has a default, unlike the PostgreSQL URL ADR 0028 gave it,
  # because a server that will not start without a variable nobody set is a
  # worse failure than one that opens a file in the state directory where the
  # TypeScript server kept auth.json. `Mealplan.Boot` still refuses if that path
  # is inside the meal-plan folder.
  config :mealplan, Mealplan.Repo,
    database:
      System.get_env("MEALPLAN_STATE") ||
        Path.expand("~/.local/state/mealplan/mealplan.db"),
    # One household, one writer. SQLite serialises writes whatever this says, and
    # a large pool only buys more connections to queue behind the same lock.
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    busy_timeout: 5_000,
    journal_mode: :wal

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # The public host comes from MEALPLAN_PUBLIC_URL (the OAuth issuer), the same
  # single source of truth server.ts used, never from a request header.
  host =
    case System.get_env("MEALPLAN_PUBLIC_URL") do
      nil -> System.get_env("PHX_HOST") || "example.com"
      url -> URI.parse(url).host || "example.com"
    end

  config :mealplan, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :mealplan, MealplanWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # exe.dev reaches the VM over eth0, not loopback, so bind every interface.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    # exe.dev terminates TLS and forwards; the MCP transport does its own Host
    # allow-listing (DNS-rebinding protection) once Phase 3 lands.
    check_origin: false,
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :mealplan, MealplanWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :mealplan, MealplanWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
