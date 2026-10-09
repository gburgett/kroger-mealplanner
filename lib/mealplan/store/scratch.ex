defmodule Mealplan.Store.Scratch do
  @moduledoc """
  Where the `mealplan` parser's short-lived copy of a household's documents
  lives, and how it is removed when nothing gets the chance to remove it
  politely (ADR 0038).

  `Mealplan.Store.Cli` lays the documents out in a directory of their own for
  the length of one parser run and removes it in an `after`. `after` does not
  run for SIGKILL, so the lifetime is also expressed in the layout:

      <base>/mealplan-<os pid>/           the run,     removed by whoever outlives it
      <base>/mealplan-<os pid>/cmd-<n>/   one parser run, removed by Cli.run/3

  The owner is in the name, so `sweep_stale/0` removes exactly the roots whose
  owning process is gone and leaves every live one alone. The layout dates from
  the sandbox, where a killed `yes | sort` once left 11 GB of spill behind; the
  rule it taught — one name to delete, and a sweep that knows what is stale —
  holds for any temporary copy.

  ## Where the base is

  `System.tmp_dir!()` unless `MEALPLAN_TMPDIR` names somewhere else. A tmpfs is
  a good choice for a test run and `config/runtime.exs` picks one when the
  machine has one: it is fast, and it is
  bounded.
  """

  @doc """
  This OS process's scratch root, created on first use.

  Memoised in `:persistent_term`: it is read once per command and never changes
  for the life of the process.
  """
  @spec root() :: String.t()
  def root do
    case :persistent_term.get({__MODULE__, :root}, nil) do
      nil ->
        path = Path.join(base(), "mealplan-#{:os.getpid()}")
        File.mkdir_p!(path)
        :persistent_term.put({__MODULE__, :root}, path)
        path

      path ->
        path
    end
  end

  @doc """
  A fresh directory for one parser run. The caller removes it — see
  `Mealplan.Store.Cli.run/3`, which does so in an `after`.
  """
  @spec command_dir!() :: String.t()
  def command_dir! do
    path = Path.join(root(), "cmd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  @doc """
  Remove the scratch roots of processes that are gone.

  Called at application start, which is the one moment a leftover is certainly
  finished with: a root belongs to an OS process, and a root whose process is
  not alive can hold nothing anybody wants. A root whose process IS alive is
  left alone even though it looks the same from outside — that is the whole
  reason the pid is in the name, and it is what makes this safe to run while a
  sibling `mix test` partition is mid-run.

  Never removes this process's own root, whether or not it exists yet.
  """
  @spec sweep_stale() :: :ok
  def sweep_stale do
    mine = "mealplan-#{:os.getpid()}"

    base()
    |> Path.join("mealplan-*")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == mine))
    |> Enum.filter(&stale?/1)
    |> Enum.each(&File.rm_rf/1)

    :ok
  end

  @doc """
  Remove this process's own root. Called from `Mealplan.Application.stop/1`, so
  an ordinary exit — `mix test` finishing, systemd sending SIGTERM — leaves
  nothing at all rather than an empty directory for the next start to collect.
  """
  @spec release() :: :ok
  def release do
    case :persistent_term.get({__MODULE__, :root}, nil) do
      nil ->
        :ok

      path ->
        File.rm_rf(path)
        :persistent_term.erase({__MODULE__, :root})
        :ok
    end
  end

  @doc """
  The directory the roots are made in.

  `config :mealplan, :tmp_base`, which `config/runtime.exs` sets from
  `MEALPLAN_TMPDIR` and, for a test run, from a tmpfs when the machine has one
  with room. Otherwise the system temporary directory.
  """
  @spec base() :: String.t()
  def base do
    Application.get_env(:mealplan, :tmp_base) || System.tmp_dir!()
  end

  # A root is stale when the process named in it is gone.
  #
  # Linux only, deliberately: so is the musl CLI. Anything that is not `mealplan-<digits>` is not ours to
  # judge and is left alone — including `mealplan-scenario-*` and
  # `mealplan-state-*`, which belong to the TypeScript harness.
  #
  # A recycled pid makes a stale root look alive. That costs one more cycle
  # before it is collected, which is the harmless direction to be wrong in.
  defp stale?(path) do
    case Path.basename(path) do
      "mealplan-" <> rest ->
        legacy?(rest) or dead_owner?(rest)

      _ ->
        false
    end
  end

  defp dead_owner?(pid) do
    match?({_, ""}, Integer.parse(pid)) and not File.dir?("/proc/#{pid}")
  end

  # The four names the flat layout used. Nothing creates them any more, and
  # every one of them is by definition an orphan: they were removed at the end
  # of a command that has long since finished. Every machine that ran the old
  # code has a pile of them — this one had 381, and 11 GB — so the sweep
  # collects them once rather than leaving a manual step in a release note.
  #
  # Delete this clause once the VM and every developer checkout has started at
  # least once on this version. It is a migration, not a rule.
  defp legacy?(rest) do
    String.starts_with?(rest, ["out-", "err-", "in-", "scratch-"])
  end
end
