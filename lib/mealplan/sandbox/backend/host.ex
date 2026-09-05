defmodule Mealplan.Sandbox.Backend.Host do
  @moduledoc """
  The unconfined backend: the same command, the same limits and the same
  scripts, but **no sandbox at all**. Selected only by `MEALPLAN_SANDBOX=host`,
  on purpose, for a machine that cannot build the sandbox image — a CI runner
  above all. See `Mealplan.Sandbox.HostShell` and ADR 0022.

  Thin, like `Mealplan.Sandbox.Backend.Bubblewrap`: the argv is `HostShell`,
  the spawn is `Runner`, and this module is only the behaviour's session shape.
  `preflight/1` has nothing to check — there is no mechanism to be present —
  and `confined?/0` is `false`, which is what keeps the `@security` scenarios
  from running in this mode rather than passing vacuously.
  """

  @behaviour Mealplan.Sandbox.Backend

  alias Mealplan.Sandbox.Runner

  @impl true
  def preflight(_opts), do: :ok

  @impl true
  def open(opts) do
    {:ok,
     %{
       mode: :host,
       image_root: Keyword.fetch!(opts, :image_root),
       seccomp_filter: Keyword.fetch!(opts, :seccomp_filter),
       workspace: Keyword.fetch!(opts, :folder),
       tenant: Keyword.fetch!(opts, :tenant),
       limits: Keyword.fetch!(opts, :limits),
       use_user_scope: Keyword.fetch!(opts, :use_user_scope),
       nproc_budget: Keyword.get(opts, :nproc_budget),
       timeout_ms: Keyword.fetch!(opts, :timeout_ms),
       max_output_bytes: Keyword.fetch!(opts, :max_output_bytes)
     }}
  end

  @impl true
  def run(handle, command, opts), do: Runner.run(handle, command, opts)

  @impl true
  def close(_handle), do: :ok

  @impl true
  def confined?, do: false

  @impl true
  def status_line(_opts) do
    "HOST — NOT SANDBOXED. Commands run unconfined as this user, with the " <>
      "host filesystem and network reachable. MEALPLAN_SANDBOX=host is set."
  end
end
