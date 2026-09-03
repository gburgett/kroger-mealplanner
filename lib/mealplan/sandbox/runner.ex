defmodule Mealplan.Sandbox.Runner do
  @moduledoc """
  Spawns one sandboxed command and collects its result. This is the Elixir side
  of what `src/sandbox/session.ts#spawn` did with `child_process.spawn`:

    * one bubblewrap invocation per call, wrapped by the limits chain;
    * a fresh seccomp file descriptor for every command (opened on fd 3 by
      `priv/sandbox/run.sh`, never shared, so its file offset is never inherited
      empty by a second command);
    * a wall-clock timeout that kills the whole process group;
    * a per-stream byte cap with a truncation notice.

  Erlang ports cannot pass fd 3 and merge stdout/stderr, so the wrapper script
  carries the fd and splits the streams into two files this module reads back.
  """

  alias Mealplan.Sandbox.{Bubblewrap, Limits}

  require Logger

  @type result :: %{
          stdout: String.t(),
          stderr: String.t(),
          exit_code: integer(),
          timed_out: boolean(),
          truncated: boolean(),
          duration_ms: float()
        }

  @wrapper Application.app_dir(:mealplan, "priv/sandbox/run.sh")

  @doc """
  Run `command` in the sandbox.

  Options:

    * `:image_root` (required), `:seccomp_filter` (path or nil, required)
    * `:limits` — `%Limits{}` (default `Limits.default/0`)
    * `:use_user_scope` — boolean (required)
    * `:workspace` — the meal-plan folder (required)
    * `:tenant` — names the transient scope unit (required)
    * `:timeout_ms` — default 10_000
    * `:max_output_bytes` — per stream, default 65_536
    * `:env` — extra `--setenv` map for the command
    * `:input` — string piped to the command's stdin
  """
  @spec run(String.t(), keyword()) :: result()
  def run(command, opts) do
    image_root = Keyword.fetch!(opts, :image_root)
    seccomp_filter = Keyword.fetch!(opts, :seccomp_filter)
    workspace = Keyword.fetch!(opts, :workspace)
    tenant = Keyword.fetch!(opts, :tenant)
    use_user_scope = Keyword.fetch!(opts, :use_user_scope)
    limits = Keyword.get(opts, :limits) || Limits.default()
    timeout_ms = Keyword.get(opts, :timeout_ms, 10_000)
    cap = Keyword.get(opts, :max_output_bytes, 64 * 1024)
    env = Keyword.get(opts, :env, %{})
    input = Keyword.get(opts, :input)

    started = System.monotonic_time(:microsecond)

    {:ok, out_path} = tmp("out")
    {:ok, err_path} = tmp("err")

    input_path =
      case input do
        nil ->
          "-"

        content ->
          {:ok, p} = tmp("in")
          File.write!(p, content)
          p
      end

    unit_name =
      "mealplan-#{sanitise_unit(tenant)}-#{:os.getpid()}-#{System.unique_integer([:positive])}.scope"

    inner_bwrap =
      ["bwrap"] ++
        Bubblewrap.args(
          image_root: image_root,
          workspace: workspace,
          command: command,
          seccomp: seccomp_filter != nil,
          env: env
        )

    argv = Limits.wrap(inner_bwrap, limits, use_user_scope: use_user_scope, unit_name: unit_name)

    wrapper_args =
      ["-w", @wrapper, out_path, err_path, seccomp_filter || "-", input_path, "--"] ++ argv

    port =
      Port.open({:spawn_executable, System.find_executable("setsid")}, [
        :exit_status,
        :binary,
        :hide,
        :stderr_to_stdout,
        args: wrapper_args,
        env: port_env(use_user_scope)
      ])

    timer = Process.send_after(self(), {:sandbox_timeout, port}, timeout_ms)
    {exit_code, timed_out} = await(port, unit_name, use_user_scope, false)
    Process.cancel_timer(timer)
    flush(port)

    duration_ms = (System.monotonic_time(:microsecond) - started) / 1000

    {stdout, out_trunc} = read_capped(out_path, cap)
    {stderr, err_trunc} = read_capped(err_path, cap)

    for p <- [out_path, err_path, input_path], p != "-", do: File.rm(p)

    stderr =
      if timed_out do
        sep = if stderr == "" or String.ends_with?(stderr, "\n"), do: "", else: "\n"
        stderr <> sep <> "the command timed out after #{timeout_ms} ms and was stopped\n"
      else
        stderr
      end

    %{
      stdout: stdout,
      stderr: stderr,
      exit_code: exit_code,
      timed_out: timed_out,
      truncated: out_trunc or err_trunc,
      duration_ms: duration_ms
    }
  end

  # Wait for the port to exit, honouring a timeout message by killing the tree.
  # The wrapper redirects the command's streams to files, so any port `:data`
  # is only the wrapper/setsid's own noise (e.g. "child did not exit normally"
  # after a group kill) — dropped.
  defp await(port, unit_name, use_user_scope, timed_out?) do
    receive do
      {^port, {:exit_status, status}} ->
        {status, timed_out?}

      {^port, {:data, _}} ->
        await(port, unit_name, use_user_scope, timed_out?)

      {:sandbox_timeout, ^port} ->
        kill_tree(port, unit_name, use_user_scope)
        await(port, unit_name, use_user_scope, true)
    end
  end

  defp flush(port) do
    receive do
      {^port, {:data, _}} -> flush(port)
      {^port, {:exit_status, _}} -> :ok
    after
      0 -> :ok
    end

    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
  catch
    _, _ -> :ok
  end

  # The negative pid is the process group. `setsid` put the whole chain in its
  # own group, and bwrap is pid 1 of the sandbox pid namespace, so killing the
  # group takes every process in the sandbox with it. Mirrors session.ts#killTree.
  defp kill_tree(port, unit_name, use_user_scope) do
    if use_user_scope do
      _ =
        System.cmd("systemctl", ["--user", "kill", "--signal=KILL", unit_name],
          env: Limits.systemd_env(),
          stderr_to_stdout: true
        )
    end

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        pgid =
          case System.cmd("ps", ["-o", "pgid=", "-p", Integer.to_string(os_pid)],
                 stderr_to_stdout: true
               ) do
            {out, 0} -> String.trim(out)
            _ -> Integer.to_string(os_pid)
          end

        _ = System.cmd("kill", ["-KILL", "-#{pgid}"], stderr_to_stdout: true)
        _ = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # Only systemd-run gets anything, and only what it needs to find the user bus.
  # `env -i` inside the limits chain stops even that reaching bubblewrap.
  defp port_env(true),
    do:
      Enum.map(Limits.systemd_env(), fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}
      end)

  defp port_env(false), do: []

  # Keep the first `cap` bytes, count the rest, append the notice ports never see.
  defp read_capped(path, cap) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        kept = IO.binread(io, cap)
        kept = if kept == :eof, do: "", else: kept
        rest_size = drain_size(io)
        File.close(io)

        if rest_size > 0 do
          {kept <> "\n[output truncated at #{cap} bytes; #{rest_size} bytes omitted]\n", true}
        else
          {kept, false}
        end

      _ ->
        {"", false}
    end
  end

  defp drain_size(io) do
    case IO.binread(io, 1_000_000) do
      :eof -> 0
      data -> byte_size(data) + drain_size(io)
    end
  end

  defp tmp(kind) do
    dir = System.tmp_dir!()
    name = "mealplan-#{kind}-#{System.unique_integer([:positive])}-#{:erlang.phash2(make_ref())}"
    path = Path.join(dir, name)
    :ok = File.write(path, "")
    {:ok, path}
  end

  defp sanitise_unit(tenant) do
    tenant
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
    |> String.slice(0, 48)
    |> case do
      "" -> "tenant"
      s -> s
    end
  end
end
