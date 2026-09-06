defmodule Mealplan.Sandbox.HostShell do
  @moduledoc """
  The command line for a command that runs **without** bubblewrap, on the host's
  own filesystem. The counterpart to `Mealplan.Sandbox.Bubblewrap`, and the
  reason `MEALPLAN_SANDBOX=host` exists.

  ## This is not a security boundary, and it is not pretending to be one

  `Mealplan.Sandbox.Bubblewrap` is the boundary. This module has no namespaces,
  no seccomp filter, and no image: the command runs as the server's own user,
  against the real filesystem, with the host's `/usr` on `PATH`. A command that
  reads `/etc/passwd`, opens a socket or writes outside the meal-plan folder
  will SUCCEED here. Everything `features/sandbox.feature` asserts under
  `@security` is false in this mode, which is why those scenarios refuse to run
  in it rather than passing vacuously.

  It exists so the application logic — the corpus, the documents, the git
  history, the shopping list arithmetic — can be tested on a machine that has no
  sandbox image and may not be allowed to build one, such as a CI runner. See
  ADR 0022.

  ## The process group is still cleaned up

  A pid namespace collects a command's whole process tree for the other two
  backends. Host mode has none, so `Mealplan.Sandbox.Runner` spawns the wrapper
  with no `setsid` layer — the BEAM already puts the port in its own session —
  and, once the command returns, sends `kill -KILL` to the command's process
  group. That one signal is the kernel taking the whole tree. Without it a
  backgrounded process outlived its command and a whole suite of them exhausted
  the machine. See `reap_group/1`, ADR 0034 and
  `docs/test-suite-oom-findings.md`.

  ## What it does keep

  Everything that is not the boundary itself, so a scenario behaves the same in
  both modes:

    * the same shell scripts, through `MEALPLAN_WORKSPACE` (`Mealplan.Corpus.Paths`);
    * the same `prlimit` rlimits, so the file-size cap still bites;
    * the same `env -i`, supplied by `Mealplan.Sandbox.Limits.wrap/3`, so the
      server's environment does not reach the command;
    * the same environment the sandbox sets — `PATH`, `HOME`, `GIT_PAGER`,
      `GIT_EDITOR` — and the same working directory, set by the port rather than
      by `--chdir`.
  """

  @doc """
  Build the argument list that follows `env -i` in the limits chain.

  `Mealplan.Sandbox.Limits.wrap/3` puts `/usr/bin/env -i` immediately before
  this, so the leading `NAME=value` words are what `env` sets and nothing else
  survives from the server's environment.

    * `:workspace` — the meal-plan folder. The command's working directory and
      its `HOME`, exactly as `/workspace` is under bubblewrap.
    * `:command` — passed to `bash -c`
    * `:env` — extra pairs (used to freeze git's clock, and to carry
      `MEALPLAN_PATH` for the corpus scripts)
  """
  @spec args(keyword()) :: [String.t()]
  def args(opts) do
    workspace = Keyword.fetch!(opts, :workspace)
    command = Keyword.fetch!(opts, :command)
    env = Keyword.get(opts, :env, %{})

    base = %{
      "PATH" => path(),
      "HOME" => workspace,
      "GIT_PAGER" => "cat",
      "GIT_EDITOR" => "true"
    }

    assignments =
      base
      |> Map.merge(Map.new(env, fn {k, v} -> {to_string(k), to_string(v)} end))
      |> Enum.sort()
      |> Enum.map(fn {name, value} -> "#{name}=#{value}" end)

    assignments ++ ["bash", "-c", command]
  end

  @doc """
  What `PATH` the command gets.

  The host's own `PATH`, with the `mealplan` binary's directory in front of it.
  `mealplan` is the one program the corpus needs that a runner will not have
  installed: under bubblewrap it is staged into the image by `cli/build.sh`, and
  here it has to be found on the host. `MEALPLAN_CLI_PATH` names its directory;
  otherwise the two places `cli/build.sh` leaves it are tried in turn.
  """
  @spec path() :: String.t()
  def path do
    host = System.get_env("PATH") || "/usr/local/bin:/usr/bin:/bin"

    case cli_dir() do
      nil -> host
      dir -> dir <> ":" <> host
    end
  end

  defp cli_dir do
    # Absolute, always. The command's working directory is the meal-plan folder,
    # so a relative PATH entry would be resolved against that folder and the
    # binary would not be found — `mealplan: command not found`, in every
    # scenario that runs the CLI.
    candidates =
      [System.get_env("MEALPLAN_CLI_PATH")] ++
        [
          "sandbox-image/rootfs/usr/bin",
          "cli/target/x86_64-unknown-linux-musl/release"
        ]

    candidates
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.find(&File.exists?(Path.join(&1, "mealplan")))
  end
end
