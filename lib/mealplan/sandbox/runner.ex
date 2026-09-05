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

  alias Mealplan.Sandbox.{Bubblewrap, HostShell, Limits, Scratch}

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
    * `:nproc_budget` — the session's precomputed
      `Mealplan.Sandbox.Limits.nproc_budget/2` result, or `nil` when
      `:use_user_scope` is true. Computed fresh if omitted — a one-off caller
      only pays for it once either way.
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

    nproc_budget =
      Keyword.get_lazy(opts, :nproc_budget, fn -> Limits.nproc_budget(limits, use_user_scope) end)
    timeout_ms = Keyword.get(opts, :timeout_ms, 10_000)
    cap = Keyword.get(opts, :max_output_bytes, 64 * 1024)
    env = Keyword.get(opts, :env, %{})
    input = Keyword.get(opts, :input)
    mode = Keyword.get(opts, :mode, :bubblewrap)

    started = System.monotonic_time(:microsecond)

    # One directory holds everything this command needs and nothing outside it
    # wants: the two stream files, its stdin, and the TMPDIR it writes to
    # itself. The `after` below removes the lot, so no path out of this function
    # — including a raise — can leak them. See Mealplan.Sandbox.Scratch for what
    # happens when there is no path out at all.
    dir = Scratch.command_dir!()

    try do
      do_run(dir, command, %{
        image_root: image_root,
        seccomp_filter: seccomp_filter,
        workspace: workspace,
        tenant: tenant,
        use_user_scope: use_user_scope,
        nproc_budget: nproc_budget,
        limits: limits,
        timeout_ms: timeout_ms,
        cap: cap,
        env: env,
        input: input,
        mode: mode,
        started: started
      })
    after
      File.rm_rf(dir)
    end
  end

  defp do_run(dir, command, o) do
    %{
      image_root: image_root,
      seccomp_filter: seccomp_filter,
      workspace: workspace,
      tenant: tenant,
      use_user_scope: use_user_scope,
      nproc_budget: nproc_budget,
      limits: limits,
      timeout_ms: timeout_ms,
      cap: cap,
      env: env,
      input: input,
      mode: mode,
      started: started
    } = o

    out_path = touch!(Path.join(dir, "out"))
    err_path = touch!(Path.join(dir, "err"))

    input_path =
      case input do
        nil ->
          "-"

        content ->
          path = Path.join(dir, "in")
          File.write!(path, content)
          path
      end

    unit_name =
      "mealplan-#{sanitise_unit(tenant)}-#{:os.getpid()}-#{System.unique_integer([:positive])}.scope"

    # The corpus scripts address the folder through MEALPLAN_WORKSPACE rather
    # than a literal path, because the two modes mount it in different places:
    # bubblewrap binds it at /workspace, the host runs in it directly. See
    # Mealplan.Corpus.Paths.
    env = Map.put(env, "MEALPLAN_WORKSPACE", workspace_root(mode, workspace))

    {inner, seccomp_arg, cwd} =
      case mode do
        :bubblewrap ->
          bwrap =
            ["bwrap"] ++
              Bubblewrap.args(
                image_root: image_root,
                workspace: workspace,
                command: command,
                seccomp: seccomp_filter != nil,
                env: env
              )

          # bubblewrap does its own --chdir /workspace, so the port needs no cwd,
          # and its --tmpfs /tmp is the command's scratch space.
          {bwrap, seccomp_filter || "-", nil}

        :host ->
          # Bubblewrap gives the command a `--tmpfs /tmp` that is discarded with
          # the sandbox. Nothing does that on the host, so a command that spills
          # to /tmp — `sort` does, and the shopping list sorts — leaves the file
          # behind when it is killed. Unnoticed, that filled a disk with 112,000
          # `sort*` files and took PostgreSQL down with it. A TMPDIR inside this
          # command's directory is the same lifetime by other means: it goes
          # when the directory goes, and the directory goes in an `after`.
          tmpdir = Path.join(dir, "tmp")
          File.mkdir_p!(tmpdir)

          shell =
            HostShell.args(
              workspace: workspace,
              command: command,
              env: Map.put(env, "TMPDIR", tmpdir)
            )

          # No image, so no filter to open, and the working directory is the
          # folder itself rather than a mount point inside a namespace.
          {shell, "-", workspace}
      end

    argv =
      Limits.wrap(inner, limits,
        use_user_scope: use_user_scope,
        nproc_budget: nproc_budget,
        unit_name: unit_name
      )

    wrapper_args =
      ["-w", @wrapper, out_path, err_path, seccomp_arg, input_path, "--"] ++ argv

    port =
      Port.open(
        {:spawn_executable, System.find_executable("setsid")},
        [
          :exit_status,
          :binary,
          :hide,
          :stderr_to_stdout,
          args: wrapper_args,
          env: port_env(use_user_scope)
        ] ++ if(cwd, do: [cd: cwd], else: [])
      )

    timer = Process.send_after(self(), {:sandbox_timeout, port}, timeout_ms)
    {exit_code, timed_out} = await(port, unit_name, use_user_scope, false)
    Process.cancel_timer(timer)
    flush(port)

    duration_ms = (System.monotonic_time(:microsecond) - started) / 1000

    {stdout, out_trunc} = read_capped(out_path, cap)
    {stderr, err_trunc} = read_capped(err_path, cap)

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

  # Where the meal-plan folder appears to the command. Bubblewrap binds it at a
  # fixed mount point; the host has no mount and uses the real path.
  defp workspace_root(:bubblewrap, _workspace), do: "/workspace"
  defp workspace_root(:host, workspace), do: workspace

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

  # The wrapper redirects onto these, so they have to exist before it runs.
  defp touch!(path) do
    :ok = File.write(path, "")
    path
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
