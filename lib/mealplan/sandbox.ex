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
        child_opts =
          opts
          |> Keyword.merge(
            tenant: tenant,
            folder: folder,
            name: {:via, Registry, {@registry, tenant}}
          )

        case DynamicSupervisor.start_child(@supervisor, {Session, child_opts}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end

  @doc "The session pid for `tenant`, or nil."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(tenant) do
    case Registry.lookup(@registry, tenant) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # --- image / filter / wrapper locations -----------------------------------

  def default_image_root do
    config()[:image_root] || Path.join(repo_root(), "sandbox-image/rootfs")
  end

  def default_seccomp_filter do
    config()[:seccomp_filter] || Path.join(repo_root(), "sandbox-image/seccomp/filter.bpf")
  end

  defp config, do: Application.get_env(:mealplan, __MODULE__, [])

  # In dev/test this is the repository. Under a release the systemd unit sets
  # WorkingDirectory to the checkout, so cwd is still the repository.
  defp repo_root, do: File.cwd!()
end
