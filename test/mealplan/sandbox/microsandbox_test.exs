defmodule Mealplan.Sandbox.Backend.MicrosandboxTest do
  @moduledoc """
  The microsandbox backend against real libkrun microVMs.

  Excluded unless `MEALPLAN_SANDBOX=microsandbox` (the `:microsandbox` tag —
  see `test/test_helper.exs`), because every test here boots a VM. Run them
  before a release with:

      MEALPLAN_SANDBOX=microsandbox mix test --include security --include microsandbox
  """

  use ExUnit.Case, async: false

  @moduletag :microsandbox
  # A VM boot is ~1 s and `msb remove` another ~0.5 s; several per test.
  @moduletag timeout: 120_000

  alias Mealplan.Sandbox.Backend.Microsandbox
  alias Mealplan.Sandbox.Limits

  setup do
    folder = Path.join(System.tmp_dir!(), "msb-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(folder)
    {_, 0} = System.cmd("git", ["init", "-q", folder])
    on_exit(fn -> File.rm_rf(folder) end)

    opts = [
      tenant: "msbtest-#{System.unique_integer([:positive])}",
      folder: folder,
      image_root: "unused",
      seccomp_filter: "unused",
      limits: Limits.default(),
      use_user_scope: false,
      nproc_budget: nil,
      timeout_ms: 8_000,
      max_output_bytes: 64 * 1024
    ]

    {:ok, folder: folder, opts: opts}
  end

  test "preflight passes: msb on PATH, /dev/kvm read/write, image present", %{opts: opts} do
    assert Microsandbox.preflight(opts) == :ok
  end

  test "open / run / close: split streams, exit code, and a corpus write on host disk",
       %{folder: folder, opts: opts} do
    {:ok, handle} = Microsandbox.open(opts)

    try do
      basics = Microsandbox.run(handle, "echo hi; id -u; pwd", [])
      assert basics.exit_code == 0
      assert basics.stdout =~ "hi"
      assert basics.stdout =~ "/workspace"

      written = Microsandbox.run(handle, "cat > /workspace/note.md; echo saved", input: "# hello\n")
      assert written.exit_code == 0
      assert File.read!(Path.join(folder, "note.md")) == "# hello\n"

      split = Microsandbox.run(handle, "echo to-out; echo to-err >&2; exit 5", [])
      assert split.exit_code == 5
      assert String.trim(split.stdout) == "to-out"
      assert String.trim(split.stderr) == "to-err"
    after
      Microsandbox.close(handle)
    end
  end

  test "the microVM has no network", %{opts: opts} do
    {:ok, handle} = Microsandbox.open(opts)

    try do
      result = Microsandbox.run(handle, "git ls-remote https://example.com/x.git 2>&1; echo rc=$?", [])

      assert result.stdout =~
               ~r/could not resolve|resolve host|network is unreachable|no route to host|temporary failure/i

      refute result.stdout =~ "rc=0"
    after
      Microsandbox.close(handle)
    end
  end

  test "a command that eats the memory is stopped; the VM keeps answering", %{opts: opts} do
    {:ok, handle} = Microsandbox.open(opts)

    try do
      hog = Microsandbox.run(handle, "yes | sort > /dev/null", [])
      refute hog.exit_code == 0

      still = Microsandbox.run(handle, "echo still-here", [])
      assert still.exit_code == 0
      assert still.stdout =~ "still-here"
    after
      Microsandbox.close(handle)
    end
  end

  test "a command past the deadline times out at the BEAM timer", %{opts: opts} do
    {:ok, handle} = Microsandbox.open(opts)

    try do
      result = Microsandbox.run(handle, "sleep 60", [])
      assert result.timed_out
      assert result.stderr =~ ~r/timed out/i
      assert result.duration_ms < 15_000
    after
      Microsandbox.close(handle)
    end
  end

  test "close removes the microVM", %{opts: opts} do
    {:ok, handle} = Microsandbox.open(opts)
    assert msb_running?(handle.name)

    assert Microsandbox.close(handle) == :ok
    refute msb_running?(handle.name)

    # idempotent
    assert Microsandbox.close(handle) == :ok
  end

  test "sweep_orphans removes a mealplan-* microVM that no session owns", %{folder: folder} do
    name = "mealplan-orphan-#{System.unique_integer([:positive])}"

    {_, 0} =
      System.cmd(
        "msb",
        ["load", "-i", Mealplan.Sandbox.default_microsandbox_image(), "-t", "mealplan-sandbox:msb"],
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        "msb",
        ["create", "mealplan-sandbox:msb", "-n", name, "-v", "#{folder}:/workspace", "--no-net"],
        stderr_to_stdout: true
      )

    on_exit(fn -> System.cmd("msb", ["remove", "-f", name], stderr_to_stdout: true) end)

    assert msb_running?(name)

    Microsandbox.sweep_orphans()

    refute msb_running?(name)
  end

  defp msb_running?(name) do
    case System.cmd("msb", ["ls", "--format", "json"], stderr_to_stdout: true) do
      {json, 0} ->
        case Jason.decode(json) do
          {:ok, entries} -> Enum.any?(entries, &(Map.get(&1, "name") == name))
          _ -> false
        end

      _ ->
        false
    end
  end
end
