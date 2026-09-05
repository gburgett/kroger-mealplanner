defmodule Mealplan.Sandbox.Backend.Microsandbox do
  @moduledoc """
  The session-layer backend for more than one household on one machine: each
  tenant gets its own libkrun microVM, booted idle at `open/1` and torn down at
  `close/1`. See ADR 0027, and `docs/multi-tenant-isolation-trade-study.md` §9.

  ## Why this exists

  Bubblewrap gives isolation, not containment: every command runs as the host
  user, and a paying customer with unlimited attempts is a threat bubblewrap
  was never asked to carry (ADR 0008's "Revisit when… more than one household
  uses one machine"). A microVM carries it — a hostile guest sees a kernel and
  a disk of its own and nothing of the host or of another tenant.

  ## The mechanism

  Every call shells out to `msb` (microsandbox 0.6.x). No SDK, no package —
  the same rule the network tools follow.

      open/1   msb create <image> -n mealplan-<tenant> -v <folder>:/workspace
                 --no-net --security restricted -m <mem> -c 1
                 --tmpfs /run/mealplan:32M --idle-timeout 15m --max-duration 2h
               then poll `msb ping` until the guest agent answers.

      run/3    msb exec --no-tty --stream --timeout <t>s -w /workspace -e …
                 <name> -- /usr/bin/bash -c <command>
               spawned through `priv/sandbox/run.sh`, the same wrapper the
               bubblewrap runner uses: `msb exec` writes the guest's stdout and
               stderr to its own two streams, and the wrapper sends those to two
               files this module reads back under the byte cap. No in-guest
               redirection, no sentinel — `--stream` keeps the split.

      close/1  msb remove -f <name>. Idempotent.

  ## What the microVM does and does not enforce

    * **Memory** — `-m` is the VM envelope. A command that eats it is OOM-killed;
      the VM survives and answers the next command. Measured.
    * **CPU** — `-c 1`. A busy loop burns one vCPU, the tenant's own.
    * **Network** — `--no-net` removes reachability entirely, gateway DNS
      included. `getent`, `/dev/tcp`, `gawk /inet/tcp` and `git` all fail to
      reach anything.
    * **Fork bombs are NOT capped per command.** `msb exec --rlimit nproc` does
      not bite (the guest command runs as uid 0). A fork bomb spends the VM's
      own memory/CPU and, worst case, wedges that one tenant's VM until
      `close/1` disposes of it. ADR 0027 records this as an accepted downgrade;
      Fly Sprites is the escape hatch if it becomes real.
  """

  @behaviour Mealplan.Sandbox.Backend

  alias Mealplan.Sandbox.Scratch

  require Logger

  @wrapper Application.app_dir(:mealplan, "priv/sandbox/run.sh")

  # The tag a `.tar` image is loaded under. A bare ref in the config is used as
  # given instead.
  @loaded_tag "mealplan-sandbox:msb"

  @ping_deadline_ms 10_000
  @ping_interval_ms 200

  # --- preflight -----------------------------------------------------------

  @impl true
  def preflight(opts) do
    unless msb_bin() do
      raise "MEALPLAN_SANDBOX=microsandbox but `msb` is not on PATH. Install microsandbox, or unset MEALPLAN_SANDBOX to use bubblewrap."
    end

    case File.open("/dev/kvm", [:read, :write]) do
      {:ok, fd} ->
        File.close(fd)

      {:error, reason} ->
        raise "MEALPLAN_SANDBOX=microsandbox needs read/write on /dev/kvm, got #{inspect(reason)}. Check `msb doctor` and that this user is in the `kvm` group."
    end

    case image_source(opts) do
      {:tar, path} ->
        unless File.exists?(path) do
          raise "no microsandbox image at #{path}. Build it with ./sandbox-image/build.sh"
        end

      {:ref, ref} ->
        unless image_loaded?(ref) do
          raise "microsandbox image #{ref} is not loaded. `msb load` it, or point MEALPLAN_MICROSANDBOX_IMAGE at the oci.tar."
        end
    end

    :ok
  end

  # --- open --------------------------------------------------------------

  @impl true
  def open(opts) do
    tenant = Keyword.fetch!(opts, :tenant)
    folder = Keyword.fetch!(opts, :folder)
    limits = Keyword.fetch!(opts, :limits)

    ref = ensure_image!(opts)
    name = sandbox_name(tenant)

    # A leftover from a previous run of this exact tenant would make `create`
    # fail with "already exists". Remove first — cheap, and idempotent.
    _ = run_msb(["remove", "-f", name])

    args =
      [
        "create",
        ref,
        "-n",
        name,
        "-v",
        "#{folder}:/workspace",
        "-w",
        "/workspace",
        "--no-net",
        "--security",
        "restricted",
        "-m",
        to_string(limits.memory_max),
        "-c",
        "1",
        "--tmpfs",
        "/run/mealplan:32M",
        "--idle-timeout",
        "15m",
        "--max-duration",
        "2h"
      ]

    case run_msb(args) do
      {_out, 0} ->
        :ok = await_ready(name)
        Logger.info("microsandbox: #{name} up (image #{ref})")

        {:ok,
         %{
           name: name,
           image: ref,
           workspace: folder,
           timeout_ms: Keyword.fetch!(opts, :timeout_ms),
           max_output_bytes: Keyword.fetch!(opts, :max_output_bytes)
         }}

      {out, code} ->
        raise "msb create failed for #{name} (exit #{code}): #{String.trim(out)}"
    end
  end

  defp await_ready(name), do: await_ready(name, 0)

  defp await_ready(name, waited) when waited >= @ping_deadline_ms do
    raise "microsandbox #{name} did not answer `msb ping` within #{@ping_deadline_ms} ms"
  end

  defp await_ready(name, waited) do
    case run_msb(["ping", name]) do
      {_out, 0} ->
        :ok

      _ ->
        Process.sleep(@ping_interval_ms)
        await_ready(name, waited + @ping_interval_ms)
    end
  end

  # --- run -------------------------------------------------------------

  @impl true
  def run(handle, command, opts) when is_binary(command) do
    cap = Keyword.get(opts, :max_output_bytes, handle.max_output_bytes)
    env = Keyword.get(opts, :env, %{})
    input = Keyword.get(opts, :input)
    timeout_ms = handle.timeout_ms

    started = System.monotonic_time(:microsecond)
    dir = Scratch.command_dir!()

    try do
      do_run(dir, handle.name, command, %{
        cap: cap,
        env: env,
        input: input,
        timeout_ms: timeout_ms,
        started: started
      })
    after
      File.rm_rf(dir)
    end
  end

  defp do_run(dir, name, command, o) do
    out_path = touch!(Path.join(dir, "out"))
    err_path = touch!(Path.join(dir, "err"))

    input_path =
      case o.input do
        nil ->
          "-"

        content ->
          path = Path.join(dir, "in")
          File.write!(path, content)
          path
      end

    # `msb exec` kills the command at its own ceiling too, a second past ours,
    # so a wedged guest cannot outlive the call even if the BEAM timer is lost.
    msb_timeout = ceil(o.timeout_ms / 1000) + 1

    exec_argv =
      [
        msb_bin(),
        "exec",
        "--no-tty",
        "--stream",
        "--timeout",
        "#{msb_timeout}s",
        "-w",
        "/workspace"
      ] ++
        env_flags(base_env(o.env)) ++
        [name, "--", "/usr/bin/bash", "-c", command]

    wrapper_args = ["-w", @wrapper, out_path, err_path, "-", input_path, "--"] ++ exec_argv

    port =
      Port.open(
        {:spawn_executable, System.find_executable("setsid")},
        [
          :exit_status,
          :binary,
          :hide,
          :stderr_to_stdout,
          args: wrapper_args,
          env: port_env()
        ]
      )

    timer = Process.send_after(self(), {:msb_timeout, port}, o.timeout_ms)
    {exit_code, timed_out} = await(port, false)
    Process.cancel_timer(timer)
    flush(port)

    duration_ms = (System.monotonic_time(:microsecond) - o.started) / 1000

    {stdout, out_trunc} = read_capped(out_path, o.cap)
    {stderr, err_trunc} = read_capped(err_path, o.cap)

    stderr =
      if timed_out do
        sep = if stderr == "" or String.ends_with?(stderr, "\n"), do: "", else: "\n"
        stderr <> sep <> "the command timed out after #{o.timeout_ms} ms and was stopped\n"
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

  defp await(port, timed_out?) do
    receive do
      {^port, {:exit_status, status}} ->
        {status, timed_out?}

      {^port, {:data, _}} ->
        await(port, timed_out?)

      {:msb_timeout, ^port} ->
        # Kill the `msb exec` client on the host. The guest command is reaped by
        # `msb exec --timeout` a second later — that ceiling is agent-enforced
        # and survives the client being killed, so a runaway cannot outlive the
        # call. An in-guest `kill` is deliberately NOT sent: `kill -KILL -1` as
        # uid 0 takes the guest's init with it and wedges the whole microVM.
        kill_tree(port)
        await(port, true)
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

  defp kill_tree(port) do
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

  # --- close ----------------------------------------------------------

  @impl true
  def close(%{name: name}) when is_binary(name) do
    _ = run_msb(["remove", "-f", name])
    :ok
  end

  def close(_), do: :ok

  # --- the sweep ----------------------------------------------------

  @doc """
  Remove `mealplan-*` microVMs that no live `Mealplan.Sandbox.Session` owns.

  Called from `Mealplan.Application.start/1` in `:microsandbox` mode, next to
  `Mealplan.Sandbox.Scratch.sweep_stale/0`: a SIGKILLed BEAM runs no
  `terminate/2`, so its tenants' microVMs would otherwise be left running.
  """
  @spec sweep_orphans() :: :ok
  def sweep_orphans do
    with bin when is_binary(bin) <- msb_bin(),
         {json, 0} <- System.cmd(bin, ["ls", "--format", "json"], stderr_to_stdout: true),
         {:ok, entries} <- Jason.decode(json) do
      ours =
        entries
        |> Enum.map(&Map.get(&1, "name"))
        |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, "mealplan-")))

      # At application start the registry is not up yet, and there can be no
      # live session before it is — so an empty set is the right answer, not a
      # crash.
      live =
        case Process.whereis(Mealplan.Sandbox.registry()) do
          nil ->
            MapSet.new()

          _ ->
            Mealplan.Sandbox.registry()
            |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
            |> Enum.map(&sandbox_name/1)
            |> MapSet.new()
        end

      for name <- ours, not MapSet.member?(live, name) do
        Logger.info("microsandbox: sweeping orphan #{name}")
        run_msb(["remove", "-f", name])
      end

      :ok
    else
      _ -> :ok
    end
  end

  # --- behaviour odds and ends ------------------------------------

  @impl true
  def confined?, do: true

  @impl true
  def status_line(opts) do
    ref =
      case image_source(opts) do
        {:tar, path} -> path
        {:ref, r} -> r
      end

    "microsandbox (libkrun microVM), image #{ref}, per-tenant session, KVM read/write"
  end

  # --- msb plumbing ---------------------------------------------

  defp msb_bin, do: System.find_executable("msb")

  defp run_msb(args) do
    case msb_bin() do
      nil -> {"`msb` not found", 127}
      bin -> System.cmd(bin, args, stderr_to_stdout: true)
    end
  rescue
    e -> {Exception.message(e), 127}
  end

  # The command inside the guest gets exactly the environment bubblewrap gives
  # it — nothing of the server's — plus the per-call additions (git's frozen
  # clock, MEALPLAN_PATH for the corpus scripts). The folder is bound at
  # /workspace, so MEALPLAN_WORKSPACE is that fixed path (Mealplan.Corpus.Paths).
  defp base_env(extra) do
    Map.merge(
      %{
        "PATH" => "/usr/bin",
        "HOME" => "/workspace",
        "MEALPLAN_WORKSPACE" => "/workspace",
        "TMPDIR" => "/run/mealplan",
        "GIT_PAGER" => "cat",
        "GIT_EDITOR" => "true"
      },
      Map.new(extra, fn {k, v} -> {to_string(k), to_string(v)} end)
    )
  end

  defp env_flags(env) do
    env
    |> Enum.sort()
    |> Enum.flat_map(fn {k, v} -> ["-e", "#{k}=#{v}"] end)
  end

  # `msb` is a host-side client, not the boundary, so it keeps the server's
  # environment (it needs MSB_HOME, XDG_*, PATH to reach its own store and
  # supervisor). `env -i` is for the guest command, and that scrub happens
  # inside the VM.
  defp port_env do
    Enum.map(System.get_env(), fn {k, v} ->
      {String.to_charlist(k), String.to_charlist(v)}
    end)
  end

  defp sandbox_name(tenant), do: "mealplan-" <> sanitise(tenant)

  defp sanitise(tenant) do
    tenant
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
    |> String.slice(0, 100)
    |> case do
      "" -> "tenant"
      s -> s
    end
  end

  # --- the image ----------------------------------------------

  defp image_source(opts) do
    configured =
      Keyword.get(opts, :microsandbox_image) ||
        Application.get_env(:mealplan, Mealplan.Sandbox, [])[:microsandbox_image] ||
        Mealplan.Sandbox.default_microsandbox_image()

    if String.ends_with?(configured, ".tar"), do: {:tar, configured}, else: {:ref, configured}
  end

  defp ensure_image!(opts) do
    case image_source(opts) do
      {:ref, ref} ->
        ref

      {:tar, path} ->
        unless image_loaded?(@loaded_tag) do
          case run_msb(["load", "-i", path, "-t", @loaded_tag]) do
            {_out, 0} -> :ok
            {out, code} -> raise "msb load #{path} failed (exit #{code}): #{String.trim(out)}"
          end
        end

        @loaded_tag
    end
  end

  defp image_loaded?(ref) do
    case run_msb(["image", "ls"]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.any?(&(&1 |> String.split() |> List.first() == ref))

      _ ->
        false
    end
  end

  # --- shared with the bubblewrap runner ----------------------

  defp touch!(path) do
    :ok = File.write(path, "")
    path
  end

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
end
