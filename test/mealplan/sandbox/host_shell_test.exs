defmodule Mealplan.Sandbox.HostShellTest do
  use ExUnit.Case, async: true

  alias Mealplan.Sandbox.HostShell

  # `HostShell.path/0` prepends the `mealplan` binary's directory to the host
  # PATH so a host-mode command can find the CLI. The directory it picks must
  # hold ONLY `mealplan` — `sandbox-image/rootfs/usr/bin` holds the whole musl
  # coreutils suite alongside it, and those binaries are dynamically linked to
  # `/lib/ld-musl-x86_64.so.1`, which does not exist on a glibc host. Putting
  # that directory on PATH poisons the command: the host's `realpath` is
  # shadowed by a musl one that fails with "cannot execute: required file not
  # found", and every corpus read/write breaks.
  #
  # `mealplan` itself is static-pie and runs anywhere; the musl coreutils do
  # not. So the only safe source directory is the cargo release dir, which
  # holds `mealplan` and nothing else that could shadow a host tool.

  @musl_rootfs "sandbox-image/rootfs/usr/bin"

  test "path/0 never puts the musl rootfs on PATH" do
    # The CLI is built in this checkout, so `cli_dir/0` has a real candidate.
    # Whatever it picks, the musl rootfs must not appear.
    refute HostShell.path() =~ @musl_rootfs,
           "the musl rootfs is on the host PATH and would shadow host coreutils"
  end

  test "an empty MEALPLAN_CLI_PATH is treated as unset, not as the cwd" do
    previous = System.get_env("MEALPLAN_CLI_PATH")
    System.put_env("MEALPLAN_CLI_PATH", "")
    try do
      path = HostShell.path()
      refute path =~ @musl_rootfs
      # An empty entry would collapse to the cwd (the repo root) under
      # `Path.expand/1`, which is not a place to find `mealplan` either.
      refute String.starts_with?(path, ":")
      refute String.ends_with?(path, ":")
    after
      if previous, do: System.put_env("MEALPLAN_CLI_PATH", previous), else: System.delete_env("MEALPLAN_CLI_PATH")
    end
  end

  test "MEALPLAN_CLI_PATH pointing at a mealplan dir leads the PATH" do
    dir = Path.join(System.tmp_dir!(), "hostshell-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mealplan"), "")
    on_exit(fn -> File.rm_rf(dir) end)

    previous = System.get_env("MEALPLAN_CLI_PATH")
    System.put_env("MEALPLAN_CLI_PATH", dir)
    try do
      path = HostShell.path()
      assert String.starts_with?(path, dir <> ":"),
             "the configured CLI directory should lead the PATH:\n#{path}"
      refute path =~ @musl_rootfs
    after
      if previous, do: System.put_env("MEALPLAN_CLI_PATH", previous), else: System.delete_env("MEALPLAN_CLI_PATH")
    end
  end
end
