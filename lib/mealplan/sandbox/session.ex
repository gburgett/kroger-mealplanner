defmodule Mealplan.Sandbox.Session do
  @moduledoc """
  The sandbox session: `open(tenant)` / `run(command)` / `close()`.

  Ported from `src/sandbox/session.ts`. On the BEAM the serialisation the
  TypeScript version got from a promise chain (`#queue` / `enqueue`) is the
  GenServer mailbox: one message is handled to completion before the next, so
  `run/3` and every corpus operation are serialised by construction, with no
  chain to get wrong. Composite operations that must not interleave with a bash
  command (write-then-commit) are single messages here rather than two calls.

  Exactly one session process exists per tenant — see `Mealplan.Sandbox` — which
  is what keeps that guarantee true when the weekly recheck job checks out the
  tenant's existing session instead of opening a second one over the same folder.
  """

  use GenServer

  alias Mealplan.Sandbox.{Limits, Runner}
  alias Mealplan.Corpus.Paths

  require Logger

  @call_timeout 120_000

  defstruct [
    :tenant,
    :folder,
    :image_root,
    :seccomp_filter,
    :limits,
    :timeout_ms,
    :max_output_bytes,
    :use_user_scope
  ]

  # --- client ---------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc "One command, one bubblewrap invocation. No auto-commit."
  def run(pid, command, opts \\ []), do: GenServer.call(pid, {:run, command, opts}, @call_timeout)

  @doc "Run a command, then commit if it changed anything — atomically."
  def run_and_commit(pid, command, message, at),
    do: GenServer.call(pid, {:run_and_commit, command, message, at}, @call_timeout)

  @doc "One corpus document, in full. Raises on a path outside the folder."
  def read_corpus(pid, path), do: GenServer.call(pid, {:read_corpus, path}, @call_timeout)

  @doc "Write one corpus document. No commit. For scaffold/migrations."
  def write_corpus(pid, path, content),
    do: GenServer.call(pid, {:write_corpus, path, content}, @call_timeout)

  @doc "Write one corpus document, then commit if it changed anything — atomically."
  def write_and_commit(pid, path, content, message, at),
    do: GenServer.call(pid, {:write_and_commit, path, content, message, at}, @call_timeout)

  @doc "`:file` | `:dir` | `:missing` for a corpus path."
  def exists_corpus(pid, path), do: GenServer.call(pid, {:exists_corpus, path}, @call_timeout)

  @doc "Entries directly inside the folder root and each of `dirs`."
  def list_corpus(pid, dirs), do: GenServer.call(pid, {:list_corpus, dirs}, @call_timeout)

  @doc "Stage everything and commit, only if the working tree differs from HEAD."
  def commit_if_changed(pid, message, at),
    do: GenServer.call(pid, {:commit_if_changed, message, at}, @call_timeout)

  @doc "Run an arbitrary function with a raw-run closure, holding the session slot."
  def transaction(pid, fun) when is_function(fun, 1),
    do: GenServer.call(pid, {:transaction, fun}, @call_timeout)

  def config(pid), do: GenServer.call(pid, :config, @call_timeout)
  def folder(pid), do: config(pid).folder

  def close(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal), else: :ok
  end

  # --- server -------------------------------------------------------------

  @impl true
  def init(opts) do
    folder = Keyword.fetch!(opts, :folder)
    File.mkdir_p!(folder)

    image_root = Keyword.get(opts, :image_root) || Mealplan.Sandbox.default_image_root()

    seccomp_filter =
      Keyword.get(opts, :seccomp_filter) || Mealplan.Sandbox.default_seccomp_filter()

    unless File.exists?(Path.join([image_root, "usr", "bin", "bash"])) do
      raise "no sandbox image at #{image_root}. Build it with ./sandbox-image/build.sh"
    end

    unless File.exists?(seccomp_filter) do
      raise "no seccomp filter at #{seccomp_filter}. Build it with ./sandbox-image/build.sh"
    end

    state = %__MODULE__{
      tenant: Keyword.fetch!(opts, :tenant),
      folder: folder,
      image_root: image_root,
      seccomp_filter: seccomp_filter,
      limits: Keyword.get(opts, :limits) || Limits.default(),
      timeout_ms: Keyword.get(opts, :timeout_ms, 10_000),
      max_output_bytes: Keyword.get(opts, :max_output_bytes, 64 * 1024),
      use_user_scope: Keyword.get_lazy(opts, :use_user_scope, &Limits.user_scope_available?/0)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:config, _from, state), do: {:reply, state, state}

  def handle_call({:run, command, opts}, _from, state) do
    {:reply, do_run(state, command, opts), state}
  end

  def handle_call({:run_and_commit, command, message, at}, _from, state) do
    result = do_run(state, command, [])
    _ = do_commit_if_changed(state, message, at)
    {:reply, result, state}
  end

  def handle_call({:read_corpus, path}, _from, state) do
    {:reply, do_read_corpus(state, path), state}
  end

  def handle_call({:write_corpus, path, content}, _from, state) do
    {:reply, do_write_corpus(state, path, content), state}
  end

  def handle_call({:write_and_commit, path, content, message, at}, _from, state) do
    reply =
      case do_write_corpus(state, path, content) do
        {:ok, bytes} ->
          _ = do_commit_if_changed(state, message, at)
          {:ok, bytes}

        other ->
          other
      end

    {:reply, reply, state}
  end

  def handle_call({:exists_corpus, path}, _from, state) do
    {:reply, do_exists_corpus(state, path), state}
  end

  def handle_call({:list_corpus, dirs}, _from, state) do
    {:reply, do_list_corpus(state, dirs), state}
  end

  def handle_call({:commit_if_changed, message, at}, _from, state) do
    {:reply, do_commit_if_changed(state, message, at), state}
  end

  def handle_call({:transaction, fun}, _from, state) do
    ctx = %{
      state: state,
      run: fn command, opts -> do_run(state, command, opts) end,
      read_corpus: fn path -> do_read_corpus(state, path) end,
      write_corpus: fn path, content -> do_write_corpus(state, path, content) end,
      exists_corpus: fn path -> do_exists_corpus(state, path) end,
      commit_if_changed: fn message, at -> do_commit_if_changed(state, message, at) end
    }

    reply =
      try do
        {:ok, fun.(ctx)}
      rescue
        e -> {:error, Exception.message(e)}
      end

    {:reply, reply, state}
  end

  # --- the mechanics ----------------------------------------------------

  defp do_run(state, command, opts) do
    Runner.run(command,
      image_root: state.image_root,
      seccomp_filter: state.seccomp_filter,
      workspace: state.folder,
      tenant: state.tenant,
      use_user_scope: state.use_user_scope,
      limits: state.limits,
      timeout_ms: state.timeout_ms,
      max_output_bytes: Keyword.get(opts, :max_output_bytes, state.max_output_bytes),
      env: Keyword.get(opts, :env, %{}),
      input: Keyword.get(opts, :input)
    )
  end

  # Every corpus read/write runs inside the sandbox. The path travels as
  # MEALPLAN_PATH (never interpolated), content on stdin. `realpath -m`
  # canonicalises in the same namespace an agent would plant a symlink in.
  defp do_read_corpus(state, path) do
    result =
      do_run(state, Paths.read_script(),
        env: %{"MEALPLAN_PATH" => path},
        max_output_bytes: state.limits.file_size_max
      )

    cond do
      result.truncated ->
        {:error,
         "could not read \"#{path}\": the file is larger than the #{state.limits.file_size_max} byte limit on one corpus document, and was not read."}

      result.exit_code == Paths.outside_folder_code() ->
        {:error, Paths.outside_folder_message(path)}

      result.exit_code != 0 ->
        {:error, "could not read \"#{path}\": #{clean_stderr(result)}"}

      true ->
        {:ok, result.stdout}
    end
  end

  defp do_write_corpus(state, path, content) do
    result =
      do_run(state, Paths.write_script(), env: %{"MEALPLAN_PATH" => path}, input: content)

    cond do
      result.exit_code == Paths.outside_folder_code() ->
        {:error, Paths.outside_folder_message(path)}

      result.exit_code != 0 ->
        {:error, "could not write \"#{path}\": #{clean_stderr(result)}"}

      true ->
        {:ok, byte_size(content)}
    end
  end

  defp do_exists_corpus(state, path) do
    result = do_run(state, Paths.stat_script(), env: %{"MEALPLAN_PATH" => path})

    cond do
      result.exit_code == Paths.outside_folder_code() ->
        {:error, Paths.outside_folder_message(path)}

      result.exit_code != 0 ->
        {:error, "could not check \"#{path}\": #{clean_stderr(result)}"}

      true ->
        case String.trim(result.stdout) do
          "dir" -> {:ok, :dir}
          "file" -> {:ok, :file}
          "missing" -> {:ok, :missing}
          other -> {:error, "could not check \"#{path}\": unexpected output \"#{other}\""}
        end
    end
  end

  defp do_list_corpus(state, dirs) do
    result = do_run(state, Paths.list_script(dirs), max_output_bytes: state.limits.file_size_max)

    cond do
      result.truncated ->
        {:error,
         "could not list the meal-plan folder: the listing is larger than the #{state.limits.file_size_max} byte limit, and was not read in full."}

      result.exit_code != 0 ->
        {:error, "could not list the meal-plan folder: #{clean_stderr(result)}"}

      true ->
        entries =
          result.stdout
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            [dir, name] = String.split(line, "\t", parts: 2)
            %{dir: dir, name: name}
          end)

        {:ok, entries}
    end
  end

  @commit_if_changed """
  if [ -n "$(git status --porcelain)" ]; then
    git add -A && git commit -q -m "$MEALPLAN_COMMIT_MESSAGE"
  fi
  """

  defp do_commit_if_changed(state, message, %DateTime{} = at) do
    env =
      Mealplan.Git.Commit.commit_environment(at)
      |> Map.put("MEALPLAN_COMMIT_MESSAGE", message)

    do_run(state, String.trim(@commit_if_changed), env: env)
  end

  defp clean_stderr(result) do
    case String.trim(result.stderr) do
      "" -> "exit status #{result.exit_code}"
      s -> s
    end
  end
end
