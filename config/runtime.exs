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
  owner: get.("MEALPLAN_OWNER", "gordon@gordonburgett.net"),
  folder: get.("MEALPLAN_FOLDER", Path.expand("~/meal-plan")),
  tenant: get.("MEALPLAN_TENANT", "household"),
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
  llm_base: System.get_env("MEALPLAN_LLM_BASE")

config :mealplan, Mealplan.Sandbox,
  image_root: System.get_env("MEALPLAN_IMAGE_ROOT"),
  seccomp_filter: System.get_env("MEALPLAN_SECCOMP_FILTER")

# The frozen clock. The Cucumber suite runs the release as its own OS process
# and cannot inject a `now` function, so it pins the instant through
# MEALPLAN_CLOCK (ISO 8601). `Mealplan.Clock` reads it back. Mirrors the
# `now: Clock` option the TypeScript `startServer` took.
if clock = System.get_env("MEALPLAN_CLOCK") do
  config :mealplan, :clock, clock
end

# The database lives outside the meal-plan folder by construction. `mix release`
# and dev both accept DATABASE_URL; dev falls back to the config/dev.exs values.
if url = System.get_env("DATABASE_URL") do
  config :mealplan, Mealplan.Repo, url: url
end

# The Cucumber harness (features/support/world.ts) spawns this app as a real
# server on a reserved port and drives it over loopback, the same way the
# TypeScript `startServer` was driven in-process. `mix test` (ExUnit) keeps the
# Ecto SQL sandbox and no HTTP server; CUCUMBER=1 turns both on.
if config_env() == :test and System.get_env("CUCUMBER") do
  config :mealplan, MealplanWeb.Endpoint, server: true

  config :mealplan, Mealplan.Repo,
    pool: DBConnection.ConnectionPool,
    pool_size: 10
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :mealplan, Mealplan.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

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
