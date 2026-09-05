defmodule Mealplan.Sandbox.ScratchTest do
  @moduledoc """
  The cleanup guarantees, asserted rather than assumed.

  These exist because the assumption was wrong once and it cost a disk. A
  command's scratch files were removed on the last line of
  `Mealplan.Sandbox.Runner.run/2`, which a killed command never reaches, and
  nothing looked for the leftovers afterwards. The memory-limit scenario's
  `yes | sort` left 11 GB of spill in one of them and filled this VM to 94%.
  """

  use ExUnit.Case, async: false

  alias Mealplan.Sandbox.Scratch

  setup do
    # A base of this test's own, so nothing here can see — or remove — the
    # roots of the run it is part of, or of a partition running beside it.
    #
    # `Scratch.root/0` memoises its answer in `:persistent_term` for the life
    # of the OS process, so `tmp_base` alone is not enough: whichever test
    # calls `root/0` or `command_dir!/0` first — here or in an ordinary
    # sandboxed command elsewhere in the same suite — fixes it for every test
    # afterward. `release/0` erased that memo but the live suite around it
    # promptly recomputed it from the SAME shared `tmp_base`, so "release/0
    # removes the root" was deleting a directory a still-running scenario's
    # session was using. Erase and restore the memo here too, so this file's
    # `root/0` and `command_dir!/0` calls always see this test's own base.
    base = Path.join(System.tmp_dir!(), "scratch-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    previous_base = Application.get_env(:mealplan, :tmp_base)
    previous_root = :persistent_term.get({Scratch, :root}, nil)
    Application.put_env(:mealplan, :tmp_base, base)
    :persistent_term.erase({Scratch, :root})

    on_exit(fn ->
      if previous_base,
        do: Application.put_env(:mealplan, :tmp_base, previous_base),
        else: Application.delete_env(:mealplan, :tmp_base)

      if previous_root,
        do: :persistent_term.put({Scratch, :root}, previous_root),
        else: :persistent_term.erase({Scratch, :root})

      File.rm_rf(base)
    end)

    {:ok, base: base}
  end

  defp plant(base, name) do
    path = Path.join(base, name)
    File.mkdir_p!(Path.join(path, "cmd-1"))
    File.write!(Path.join([path, "cmd-1", "out"]), "something worth losing")
    path
  end

  # A pid that is certainly not running. The kernel hands them out below
  # /proc/sys/kernel/pid_max, and 4194303 is the ceiling on 64-bit Linux.
  @dead_pid 4_194_303

  describe "sweep_stale/0" do
    test "removes the root of a process that is gone", %{base: base} do
      stale = plant(base, "mealplan-#{@dead_pid}")

      Scratch.sweep_stale()

      refute File.exists?(stale)
    end

    test "leaves the root of a process that is still running", %{base: base} do
      # pid 1 is always alive. This is the property that makes the sweep safe to
      # run while `mix test --partitions` siblings are mid-run: a wildcard sweep
      # would delete their corpora out from under them, which is what the old
      # `mealplan-run-*` sweep in the Cucumber hooks did.
      live = plant(base, "mealplan-1")

      Scratch.sweep_stale()

      assert File.exists?(Path.join([live, "cmd-1", "out"]))
    end

    test "leaves this process's own root alone", %{base: base} do
      mine = plant(base, "mealplan-#{:os.getpid()}")

      Scratch.sweep_stale()

      assert File.exists?(mine)
    end

    test "leaves names that are not ours alone", %{base: base} do
      # The TypeScript harness's, which is still the runner for
      # features/sandbox.feature and cleans up after itself.
      theirs = plant(base, "mealplan-scenario-Xy12ab")
      state = plant(base, "mealplan-state-Xy12ab")

      Scratch.sweep_stale()

      assert File.exists?(theirs)
      assert File.exists?(state)
    end

    test "removes the flat names the old layout left behind", %{base: base} do
      olds =
        for name <- ~w(mealplan-out-1-2 mealplan-err-1-2 mealplan-in-1-2 mealplan-scratch-1-2) do
          path = Path.join(base, name)
          File.write!(path, "")
          path
        end

      Scratch.sweep_stale()

      for path <- olds, do: refute(File.exists?(path))
    end
  end

  describe "Runner.run/2 cleanup" do
    # These measure the DELTA, not the whole root. The root belongs to the OS
    # process, and the suite shares it: a session GenServer or a Bandit request
    # handler from another test can hold a command directory of its own while
    # these run, and that is not this function's business. Asserting the root
    # was empty made these three tests fail for other tests' work.
    setup do
      {:ok, before: command_dirs()}
    end

    # The regression test for the 11 GB. A command that is stopped by the
    # wall-clock timeout used to leave its TMPDIR — and everything the command
    # had written into it — behind, because the removal was the last line of a
    # function the timeout path reached but the killed command's spill outlived.
    test "a command that times out leaves nothing behind", %{before: before} do
      result = run_in_sandbox("sleep 5", timeout_ms: 300)

      assert result.timed_out
      assert command_dirs() -- before == []
    end

    test "a command that fails leaves nothing behind", %{before: before} do
      result = run_in_sandbox("exit 3")

      assert result.exit_code == 3
      assert command_dirs() -- before == []
    end

    test "a command that writes to TMPDIR leaves nothing behind", %{before: before} do
      # What `sort` does when it spills, and what the shopping list does for its
      # JSON: writes a file next to the command rather than into the corpus.
      result = run_in_sandbox(~s(echo spill > "${TMPDIR:-/tmp}/spill"; ls "${TMPDIR:-/tmp}"))

      assert result.exit_code == 0
      assert result.stdout =~ "spill"
      assert command_dirs() -- before == []
    end
  end

  defp command_dirs do
    Scratch.root() |> Path.join("cmd-*") |> Path.wildcard()
  end

  defp run_in_sandbox(command, opts \\ []) do
    workspace = Path.join(System.tmp_dir!(), "scratch-ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    Mealplan.Sandbox.Runner.run(
      command,
      Keyword.merge(
        [
          # These assert `Runner`'s own scratch cleanup, which is the same for
          # its two modes. Under `MEALPLAN_SANDBOX=microsandbox` the Runner is
          # not the code path at all (`Mealplan.Sandbox.Backend.Microsandbox`
          # is, with its own `after File.rm_rf/1` — see
          # `test/mealplan/sandbox/microsandbox_test.exs`), so fall back to the
          # unconfined mode `Runner` does understand.
          mode: runner_mode(),
          image_root: Mealplan.Sandbox.default_image_root(),
          seccomp_filter: Mealplan.Sandbox.default_seccomp_filter(),
          workspace: workspace,
          tenant: "scratch-test",
          use_user_scope: Mealplan.Sandbox.Limits.user_scope_available?()
        ],
        opts
      )
    )
  end

  defp runner_mode do
    case Mealplan.Sandbox.mode() do
      :microsandbox -> :host
      other -> other
    end
  end

  describe "root/0 and command_dir!/0" do
    test "a command directory is a fresh child of this process's root" do
      one = Scratch.command_dir!()
      two = Scratch.command_dir!()

      assert File.dir?(one)
      assert File.dir?(two)
      assert one != two
      assert Path.dirname(one) == Scratch.root()
      assert Path.basename(Scratch.root()) == "mealplan-#{:os.getpid()}"
    end

    test "release/0 removes the root and lets the next call rebuild it" do
      root = Scratch.root()
      Scratch.command_dir!()

      Scratch.release()

      refute File.exists?(root)
      assert File.dir?(Scratch.root())
    end
  end
end
