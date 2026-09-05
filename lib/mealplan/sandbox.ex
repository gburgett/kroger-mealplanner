defmodule Mealplan.Sandbox do
  @moduledoc """
  Opening and finding sandbox sessions.

  Exactly one `Mealplan.Sandbox.Session` process per tenant, registered by
  tenant id under a `Registry` behind a `DynamicSupervisor`. This is the
  `open(tenant)` seam ADR 0008 kept, given its multi-tenant meaning: a tenant
  resolves to its own corpus folder. The single process per tenant is what
  makes the GenServer-mailbox serialisation a real guarantee (plan 0005,
  Phase 4) and closes the two-sessions-one-folder defect ADR 0021 leaves open.
  """

  alias Mealplan.Sandbox.Session

  require Logger

  @registry Mealplan.Sandbox.Registry
  @supervisor Mealplan.Sandbox.DynamicSupervisor

  def registry, do: @registry
  def dynamic_supervisor, do: @supervisor

  @doc """
  The session for `tenant`, opening it over `folder` if it is not already up.

  With one household there is one tenant, "household", and one folder. A second
  tenant later is a new id and a new folder under a per-tenant root — a row and
  a directory, not a rewrite.
  """
  @spec open(String.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def open(tenant, folder, opts \\ []) do
    case Registry.lookup(@registry, tenant) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        :ok = evict_if_full(tenant)

        child_opts =
          opts
          |> Keyword.merge(
            tenant: tenant,
            folder: folder,
            # The value is the LRU clock: an initial timestamp here, bumped by
            # the Session on every command. `evict_if_full/1` reads it.
            name: {:via, Registry, {@registry, tenant, System.monotonic_time()}}
          )

        case DynamicSupervisor.start_child(@supervisor, {Session, child_opts}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end

  # Admission control for the one backend with a per-session live cost. When the
  # registry already holds `max_live_sessions/0` sessions and none is the tenant
  # now asking, close the least-recently-used one first — its microVM goes with
  # it (`Session.terminate/2`). Bubblewrap and host never reach this: their
  # `max_live_sessions/0` is nil.
  defp evict_if_full(tenant) do
    with limit when is_integer(limit) <- max_live_sessions(),
         entries <- live_sessions(),
         true <- length(entries) >= limit,
         false <- Enum.any?(entries, fn {key, _pid, _ts} -> key == tenant end) do
      {lru_key, lru_pid, _ts} = Enum.min_by(entries, fn {_key, _pid, ts} -> ts || 0 end)
      Logger.info("sandbox: evicting least-recently-used session #{lru_key} to admit #{tenant}")
      Session.close(lru_pid)
    end

    :ok
  end

  defp live_sessions do
    Registry.select(@registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
  end

  @doc false
  # Called by `Mealplan.Sandbox.Session` on every command: the LRU clock the
  # eviction in `open/3` sorts on.
  @spec touch(String.t()) :: :ok
  def touch(tenant) do
    _ = Registry.update_value(@registry, tenant, fn _ -> System.monotonic_time() end)
    :ok
  end

  @doc "The session pid for `tenant`, or nil."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(tenant) do
    case Registry.lookup(@registry, tenant) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # --- how a command is confined --------------------------------------------

  @doc """
  Which confinement a command runs under: `:bubblewrap` or `:host`.

  `:bubblewrap` is the product. It is the default, it is what production and a
  developer's machine run, and it is the security boundary ADR 0008 chose.

  `:host` runs the same command with the same limits and the same scripts but
  **no sandbox at all** — see `Mealplan.Sandbox.HostShell`. It exists so the
  application logic can be tested where no sandbox image can be built, and it is
  selected only by setting `MEALPLAN_SANDBOX=host` on purpose. Nothing infers
  it: a missing image is an error in `:bubblewrap` mode, never a silent
  downgrade, because a boundary that disappears when a file is missing is worse
  than one that is absent on purpose.
  """
  @spec mode() :: :bubblewrap | :host | :microsandbox
  def mode, do: config()[:mode] || :bubblewrap

  @doc """
  The `Mealplan.Sandbox.Backend` module for the configured `mode/0`.

  One switch at boot picks the confinement mechanism; every `Session` resolves
  it here and holds it for its life. See `Mealplan.Sandbox.Backend`.
  """
  @spec backend() :: module()
  def backend do
    case mode() do
      :bubblewrap -> Mealplan.Sandbox.Backend.Bubblewrap
      :host -> Mealplan.Sandbox.Backend.Host
      :microsandbox -> Mealplan.Sandbox.Backend.Microsandbox
    end
  end

  @doc "True when commands are really confined. False under `:host`."
  @spec confined?() :: boolean()
  def confined?, do: backend().confined?()

  # --- image / filter / wrapper locations -----------------------------------

  def default_image_root do
    config()[:image_root] || Path.join(repo_root(), "sandbox-image/rootfs")
  end

  def default_seccomp_filter do
    config()[:seccomp_filter] || Path.join(repo_root(), "sandbox-image/seccomp/filter.bpf")
  end

  @doc """
  The microsandbox image: a `.tar` this backend loads into `msb`, or a bare
  `msb` image reference used as given. Defaults to the `oci.tar` that
  `sandbox-image/build.sh` writes.
  """
  def default_microsandbox_image do
    config()[:microsandbox_image] || Path.join(repo_root(), "sandbox-image/oci.tar")
  end

  @doc """
  How many live tenant sessions `microsandbox` mode allows before `open/3`
  evicts the least-recently-used one to make room. `nil` means unbounded, which
  is what bubblewrap and host use — they have no per-session live cost. A
  microVM does: trade study §8 puts this VM's ceiling near two dozen.
  """
  @spec max_live_sessions() :: pos_integer() | nil
  def max_live_sessions do
    if mode() == :microsandbox, do: config()[:max_live_sessions] || 16, else: nil
  end

  defp config, do: Application.get_env(:mealplan, __MODULE__, [])

  # In dev/test this is the repository. Under a release the systemd unit sets
  # WorkingDirectory to the checkout, so cwd is still the repository.
  defp repo_root, do: File.cwd!()
end
