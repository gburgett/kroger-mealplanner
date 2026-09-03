defmodule Mealplan.Sandbox.Limits do
  @moduledoc """
  Resource limits for a sandboxed command. Ported from `src/sandbox/limits.ts`.

  Two layers, because they fail differently:

    * cgroup v2, through `systemd-run --user --scope`: `MemoryMax`, `TasksMax`
      and `CPUQuota`. The real control. `TasksMax` counts this command's tasks
      and no one else's, unlike `RLIMIT_NPROC` which counts the uid host-wide.
    * rlimits, through `prlimit(1)`: set regardless. They cost nothing and are
      the only line left when the user's systemd is not reachable.
  """

  @type t :: %__MODULE__{
          memory_max: String.t(),
          tasks_max: pos_integer(),
          cpu_quota: String.t(),
          file_size_max: pos_integer()
        }

  defstruct memory_max: "512M",
            tasks_max: 64,
            cpu_quota: "100%",
            # A recipe is a few kilobytes. 64 MB is a runaway `yes > file`.
            file_size_max: 64 * 1024 * 1024

  @doc "The default limits (`DEFAULT_LIMITS` in limits.ts)."
  @spec default() :: t()
  def default, do: %__MODULE__{}

  @doc """
  Whether `systemd-run --user --scope` can be used.

  Probed by running it, not by inspecting the environment, because the answer
  that matters is whether it works. Probed once per session, at open().
  """
  @spec user_scope_available?() :: boolean()
  def user_scope_available? do
    File.exists?(bus_path()) and
      match?(
        {_, 0},
        System.cmd("systemd-run", ~w(--user --scope --quiet --collect -- true),
          env: systemd_env(),
          stderr_to_stdout: true
        )
      )
  rescue
    _ -> false
  end

  @doc """
  The two variables `systemd-run --user` needs to find the user's bus.

  They are given to systemd-run and to nothing else: `env -i` sits between
  systemd-run and bubblewrap, so neither reaches the sandbox or /proc/1/environ.
  """
  @spec systemd_env() :: [{String.t(), String.t()}]
  def systemd_env do
    uid = uid()

    [
      {"XDG_RUNTIME_DIR", "/run/user/#{uid}"},
      {"DBUS_SESSION_BUS_ADDRESS", "unix:path=#{bus_path()}"}
    ]
  end

  defp bus_path, do: "/run/user/#{uid()}/bus"

  defp uid do
    System.cmd("id", ["-u"]) |> elem(0) |> String.trim()
  rescue
    _ -> "0"
  end

  @doc """
  Wrap `argv` so it runs under the limits. Outermost first:

      systemd-run --user --scope   the cgroup, when available
        prlimit                    the rlimits, always
          env -i                   an empty environment for pid 1 of the sandbox
            bwrap                  the boundary

  `env -i` is load-bearing: bubblewrap becomes pid 1 in the sandbox and keeps
  the environment it was launched with, so without it `cat /proc/1/environ`
  reads the server's environment. `--clearenv` only sets the child's env.
  """
  @spec wrap([String.t()], t(), keyword()) :: [String.t()]
  def wrap(argv, %__MODULE__{} = limits, opts) do
    use_user_scope = Keyword.fetch!(opts, :use_user_scope)
    unit_name = Keyword.fetch!(opts, :unit_name)

    inner =
      ["prlimit"] ++
        nproc_argument(limits, use_user_scope) ++
        ["--fsize=#{limits.file_size_max}", "--", "/usr/bin/env", "-i"] ++
        argv

    if use_user_scope do
      [
        "systemd-run",
        "--user",
        "--scope",
        "--quiet",
        "--collect",
        "--unit=#{unit_name}",
        "--property=MemoryMax=#{limits.memory_max}",
        "--property=TasksMax=#{limits.tasks_max}",
        "--property=CPUQuota=#{limits.cpu_quota}",
        "--"
      ] ++ inner
    else
      inner
    end
  end

  # RLIMIT_NPROC is an absolute count per uid, not a budget for us. With a
  # cgroup, TasksMax is the better control and this adds nothing. Without one,
  # the uid's current thread count plus headroom: a fork bomb still dies, a
  # busy machine still works.
  defp nproc_argument(_limits, true), do: []

  defp nproc_argument(%__MODULE__{tasks_max: tasks_max}, false) do
    ["--nproc=#{tasks_owned_by_this_uid() + tasks_max * 4}"]
  end

  defp tasks_owned_by_this_uid do
    uid = uid()

    case File.ls("/proc") do
      {:ok, entries} ->
        entries
        |> Enum.filter(&Regex.match?(~r/^\d+$/, &1))
        |> Enum.reduce(0, fn pid, acc ->
          with {:ok, %File.Stat{uid: puid}} <- File.stat("/proc/#{pid}"),
               true <- to_string(puid) == uid,
               {:ok, tasks} <- File.ls("/proc/#{pid}/task") do
            acc + length(tasks)
          else
            _ -> acc
          end
        end)

      _ ->
        0
    end
  end
end
