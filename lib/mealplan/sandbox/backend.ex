defmodule Mealplan.Sandbox.Backend do
  @moduledoc """
  A confinement mechanism, chosen once at boot by `MEALPLAN_SANDBOX`.

  `Mealplan.Sandbox.Session` is the same for every mechanism: one process per
  tenant, its mailbox serialising every command. What differs is where a
  command actually runs — a bubblewrap namespace, the host itself, or a libkrun
  microVM. Each of those is a `Backend`, and the `Session` holds one for its
  whole life:

      init/1   backend = Mealplan.Sandbox.backend()
               :ok       = backend.preflight(opts)   # raise, never downgrade
               {:ok, h}  = backend.open(opts)        # h is opaque to the Session

      do_run   backend.run(h, command, opts)         # a Runner.result map

      terminate backend.close(h)

  `opts` for `preflight/1` and `open/1` carry what `Session.init` computes:
  `:tenant`, `:folder`, `:image_root`, `:seccomp_filter`, `:limits`,
  `:use_user_scope`, `:nproc_budget`, `:timeout_ms`, `:max_output_bytes`. A
  backend takes what it needs and ignores the rest.

  ## Why `preflight/1` raises instead of returning an error

  A boundary that disappears when a file is missing is worse than one that is
  absent on purpose — see `Mealplan.Sandbox.mode/0`. `preflight/1` is where a
  backend proves its mechanism is really there (the image is built, `/dev/kvm`
  is writable) before the first command is allowed to run. It raises with a
  person-readable reason so the failure lands in the journal a person is still
  looking at, exactly as the inline check it replaces did.

  See ADR 0008 (bubblewrap), ADR 0022 (host mode) and ADR 0027 (microsandbox).
  """

  @typedoc "Opaque to the caller. Whatever a backend needs to run and later close a session."
  @type handle :: term()

  @doc "Raise with a person-readable reason unless this backend's mechanism is present and usable."
  @callback preflight(opts :: keyword()) :: :ok

  @doc "Acquire whatever the session holds for its life (a config map, a live microVM …)."
  @callback open(opts :: keyword()) :: {:ok, handle()}

  @doc "Run one command. The result is the unchanged `Mealplan.Sandbox.Runner.result` map."
  @callback run(handle(), command :: String.t(), opts :: keyword()) ::
              Mealplan.Sandbox.Runner.result()

  @doc "Release the handle. Idempotent: a second call, or a call on an already-gone resource, is `:ok`."
  @callback close(handle()) :: :ok

  @doc "True when a command is really confined. False only for `host`."
  @callback confined?() :: boolean()

  @doc "The one-line description `Mealplan.Boot` prints in the start-up health check."
  @callback status_line(opts :: keyword()) :: String.t()
end
