defmodule Mealplan.Sandbox.Bubblewrap do
  @moduledoc """
  The bubblewrap command line. Ported verbatim in behaviour from
  `src/sandbox/bubblewrap.ts`. Every flag earns its place; this string is the
  security boundary of the whole product. See ADR 0008.
  """

  @seccomp_fd 3
  def seccomp_fd, do: @seccomp_fd

  @doc """
  Build the `bwrap` argv (without the leading `bwrap`).

    * `:image_root` — the exported sandbox-image/rootfs directory
    * `:workspace` — the meal-plan folder on the host; the only writable path
    * `:command` — passed to `bash -c`
    * `:seccomp` — false when the image has no filter to load
    * `:env` — extra `--setenv` pairs (used to freeze git's clock)
  """
  @spec args(keyword()) :: [String.t()]
  def args(opts) do
    image_root = Keyword.fetch!(opts, :image_root)
    workspace = Keyword.fetch!(opts, :workspace)
    command = Keyword.fetch!(opts, :command)
    seccomp = Keyword.get(opts, :seccomp, true)
    env = Keyword.get(opts, :env, %{})

    usr = Path.join(image_root, "usr")

    base = [
      # A fresh namespace of every kind. The network one is what makes the
      # sandbox unable to reach anything. The pid one makes /proc/1 the
      # sandbox's own init rather than the host's systemd.
      "--unshare-all",
      # If the server dies, the sandbox dies with it.
      "--die-with-parent",
      # A new session, so the sandbox cannot push characters back with TIOCSTI.
      "--new-session",

      # The image, read-only, and nothing of the host. Never --ro-bind /usr /usr.
      "--ro-bind",
      usr,
      "/usr",
      "--symlink",
      "usr/bin",
      "/bin",
      "--symlink",
      "usr/lib",
      "/lib",

      # /proc must be a fresh mount, or /proc/1 is the host's init.
      "--proc",
      "/proc",
      "--dev",
      "/dev",
      # sort(1) spills here. It is memory, so it counts against MemoryMax.
      "--tmpfs",
      "/tmp",
      "--bind",
      workspace,
      "/workspace",
      "--chdir",
      "/workspace",

      # Nothing of the server's environment reaches the command.
      "--clearenv",
      "--setenv",
      "PATH",
      "/usr/bin",
      "--setenv",
      "HOME",
      "/workspace",
      "--setenv",
      "GIT_PAGER",
      "cat",
      "--setenv",
      "GIT_EDITOR",
      "true"
    ]

    extra_env =
      env
      |> Enum.sort()
      |> Enum.flat_map(fn {name, value} -> ["--setenv", to_string(name), to_string(value)] end)

    seccomp_args =
      if seccomp, do: ["--add-seccomp-fd", Integer.to_string(@seccomp_fd)], else: []

    base ++ extra_env ++ seccomp_args ++ ["--", "/usr/bin/bash", "-c", command]
  end
end
