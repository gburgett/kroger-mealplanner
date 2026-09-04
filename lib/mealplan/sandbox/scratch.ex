defmodule Mealplan.Sandbox.Scratch do
  @moduledoc """
  Where a sandboxed command's short-lived files live, and how they are removed
  when nothing gets the chance to remove them politely.

  A command needs four things that must not outlive it: a file for its stdout, a
  file for its stderr, a file holding its stdin, and a `TMPDIR` of its own. They
  used to be four siblings in `System.tmp_dir!()` with unique names, deleted at
  the end of `Mealplan.Sandbox.Runner.run/2`. That works exactly as long as
  `run/2` reaches its last line.

  It does not always. A command that is killed — the wall-clock timeout, a
  supervisor shutting the session down, the BEAM going away — leaves every one
  of those files behind, and nothing looks for them again. On this VM that left
  383 files in `/tmp`, one of which was a 45,000-file `sort` spill of **11 GB**
  from the memory-limit scenario, taken far enough to fill the disk to 94%.
  The scratch directory did its job (the spill was contained in one place
  instead of loose in `/tmp`); what was missing was anything that removed it.

  So the lifetime is expressed in the layout instead of only in the code:

      <base>/mealplan-<os pid>/           the run,     removed by whoever outlives it
      <base>/mealplan-<os pid>/cmd-<n>/   one command, removed by run/2

  That buys two things a flat directory of uniquely-named files cannot:

    * **One name to delete.** `run/2` removes one directory in an `after`, so an
      exception on any path between opening the port and reading the output
      cannot leak the command's files, and cannot leak whatever the command
      itself wrote to `TMPDIR`.

    * **A sweep that knows what is stale.** `after` does not run for SIGKILL, so
      something must still collect the leftovers of a process that was killed.
      The owner is in the name, so `sweep_stale/0` can remove exactly the roots
      whose owning process is gone and leave every live one alone. A wildcard
      over uniquely-named files cannot make that distinction, and would delete
      the files of a `mix test --partitions` sibling that is still running.

  ## Where the base is

  `System.tmp_dir!()` unless `MEALPLAN_TMPDIR` names somewhere else. A tmpfs is
  a good choice for a test run and `test/test_helper.exs` picks one when the
  machine has one: it is faster for the git-heavy corpus copying, and it is
  bounded, so a command that runs away hits `ENOSPC` in RAM instead of filling
  the disk PostgreSQL is on.
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
  A fresh directory for one command. The caller removes it — see
  `Mealplan.Sandbox.Runner.run/2`, which does so in an `after`.
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
  # Linux only, deliberately: so is bubblewrap, so is the musl CLI, so is the
  # systemd scope. Anything that is not `mealplan-<digits>` is not ours to
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
