defmodule Mealplan.Sandbox.Backend.Bubblewrap do
  @moduledoc """
  The default backend: every command runs in a fresh bubblewrap namespace.

  This module is deliberately thin. The boundary itself is
  `Mealplan.Sandbox.Bubblewrap` (the `bwrap` argv) and the per-command spawn,
  timeout and output cap are `Mealplan.Sandbox.Runner`; neither changed when the
  backend seam was introduced. What lives here is only the session-shaped
  wrapper the `Mealplan.Sandbox.Backend` behaviour asks for:

    * `preflight/1` — the image and seccomp-filter existence check that used to
      be inline in `Mealplan.Sandbox.Session.init/1`. A missing image raises
      here rather than downgrading to `host`.
    * `open/1` — there is no live resource, so the handle is just the resolved
      config the `Runner` needs, frozen once.
    * `run/2` — `Mealplan.Sandbox.Runner.run/3` with `mode: :bubblewrap`.
    * `close/1` — nothing to release.

  See ADR 0008.
  """

  @behaviour Mealplan.Sandbox.Backend

  alias Mealplan.Sandbox.Runner

  @impl true
  def preflight(opts) do
    image_root = Keyword.fetch!(opts, :image_root)
    seccomp_filter = Keyword.fetch!(opts, :seccomp_filter)

    unless File.exists?(Path.join([image_root, "usr", "bin", "bash"])) do
      raise "no sandbox image at #{image_root}. Build it with ./sandbox-image/build.sh"
    end

    unless File.exists?(seccomp_filter) do
      raise "no seccomp filter at #{seccomp_filter}. Build it with ./sandbox-image/build.sh"
    end

    :ok
  end

  @impl true
  def open(opts) do
    {:ok,
     %{
       mode: :bubblewrap,
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
  def confined?, do: true

  @impl true
  def status_line(opts), do: "bubblewrap, image #{Keyword.fetch!(opts, :image_root)}"
end
