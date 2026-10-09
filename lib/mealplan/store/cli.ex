defmodule Mealplan.Store.Cli do
  @moduledoc """
  The `mealplan` parser, run over a tenant's documents with no sandbox
  (ADR 0038).

  The document format is defined in one place, the Rust parser (ADR 0007), and
  the parser reads a folder. So the documents are written into a private
  directory for the length of one command, the binary runs there, and the
  directory goes in an `after`.

  Why no sandbox: the sandbox exists because the agent chose the command. Here
  it chooses nothing that is executed — the program is ours, the argument vector
  is built by the server from validated arguments, and the binary has no
  network code. What the agent supplies is document bodies and dates, and those
  are data to a parser. The environment is cleared (`env -i`), so nothing the
  server holds reaches the child even by accident.
  """

  alias Mealplan.Sandbox.Scratch

  @timeout_ms 15_000

  # stderr is split from stdout through a file, because `System.cmd/3` can only
  # merge them, and `--json` output has to arrive clean. The script is fixed
  # text; the program and its arguments arrive as positional parameters, never
  # inside the script.
  @script ~s(exec "$0" "$@" 2>"$MEALPLAN_STDERR")

  @type result :: %{
          stdout: String.t(),
          stderr: String.t(),
          exit_code: integer(),
          files: %{String.t() => String.t()}
        }

  @doc """
  Run `mealplan <args>` over `documents` (`[{path, body}]`).

  `collect:` names paths to read back out of the directory after the command —
  how `shopping-list --out` hands its document back.
  """
  @spec run([{String.t(), String.t()}], [String.t()], keyword()) ::
          {:ok, result()} | {:error, String.t()}
  def run(documents, args, opts \\ []) do
    with {:ok, binary} <- binary() do
      dir = Path.join(Scratch.root(), "documents-#{System.unique_integer([:positive])}")
      stderr_path = dir <> ".stderr"

      try do
        File.mkdir_p!(dir)

        for {path, body} <- documents do
          full = Path.join(dir, path)
          File.mkdir_p!(Path.dirname(full))
          File.write!(full, body)
        end

        task =
          Task.async(fn ->
            System.cmd(
              "/usr/bin/env",
              ["-i", "PATH=/usr/bin:/bin", "LANG=C.UTF-8", "MEALPLAN_STDERR=" <> stderr_path] ++
                ["/bin/sh", "-c", @script, binary | args],
              cd: dir
            )
          end)

        case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, {stdout, exit_code}} ->
            files =
              opts
              |> Keyword.get(:collect, [])
              |> Enum.flat_map(fn path ->
                case File.read(Path.join(dir, path)) do
                  {:ok, body} -> [{path, body}]
                  {:error, _} -> []
                end
              end)
              |> Map.new()

            {:ok,
             %{
               stdout: stdout,
               stderr: File.read(stderr_path) |> elem_or(""),
               exit_code: exit_code,
               files: files
             }}

          nil ->
            {:error,
             "mealplan #{Enum.join(args, " ")} ran longer than #{div(@timeout_ms, 1000)} seconds and was stopped."}
        end
      rescue
        error in File.Error ->
          {:error,
           "the documents could not be laid out for the parser: #{Exception.message(error)}"}
      after
        File.rm_rf(dir)
        File.rm(stderr_path)
      end
    end
  end

  @doc """
  Where the `mealplan` binary is, or `{:error, message}` naming what to build.

  `MEALPLAN_CLI_PATH` names its directory, as host mode reads it. Otherwise the
  cargo release directory, then the copy `cli/build.sh` stages into the sandbox
  image — the binary is static, so that copy runs on the host as well.
  """
  @spec binary() :: {:ok, String.t()} | {:error, String.t()}
  def binary do
    candidates = [
      System.get_env("MEALPLAN_CLI_PATH"),
      "cli/target/x86_64-unknown-linux-musl/release",
      "sandbox-image/rootfs/usr/bin"
    ]

    candidates
    |> Enum.reject(&(is_nil(&1) or String.trim(&1) == ""))
    |> Enum.map(&Path.join(Path.expand(&1), "mealplan"))
    |> Enum.find(&File.regular?/1)
    |> case do
      nil ->
        {:error,
         "the mealplan parser is not built on this server, so documents cannot be checked. " <>
           "The operator runs ./cli/build.sh."}

      path ->
        {:ok, path}
    end
  end

  defp elem_or({:ok, value}, _default), do: value
  defp elem_or(_, default), do: default
end
