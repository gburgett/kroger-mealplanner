defmodule Mealplan.Git.Repository do
  @moduledoc """
  Make and inspect the meal-plan folder's git repository. Ported from
  `src/git/repository.ts`. Every git command runs inside the sandbox session.
  """

  alias Mealplan.Git.Commit
  alias Mealplan.Sandbox.Session

  @doc """
  Make the folder a repository with a first commit, if it is not one already.

  The first commit matters: `git restore --source=HEAD~1` and `git revert` are
  the undo button the folder otherwise does not have, and neither works in a
  repository with no history.
  """
  @spec ensure_repository(pid(), DateTime.t()) :: :ok
  def ensure_repository(session, %DateTime{} = at) do
    existing = Session.run(session, "git rev-parse --git-dir")

    if existing.exit_code == 0 do
      :ok
    else
      script =
        Enum.join(
          [
            "set -e",
            "git init -q -b main",
            "git config user.name #{Commit.quote_arg(Commit.committer_name())}",
            "git config user.email #{Commit.quote_arg(Commit.committer_email())}",
            "git add -A",
            "git commit -q -m #{Commit.quote_arg(Commit.first_commit_message())}"
          ],
          "\n"
        )

      result = Session.run(session, script, env: Commit.commit_environment(at))

      if result.exit_code != 0 do
        raise "could not make the meal-plan folder a git repository:\n" <>
                if(result.stderr == "", do: result.stdout, else: result.stderr)
      end

      :ok
    end
  end

  @doc "True when the working tree differs from HEAD."
  @spec dirty?(pid()) :: boolean()
  def dirty?(session) do
    status = Session.run(session, "git status --porcelain")
    String.trim(status.stdout) != ""
  end

  @doc "Number of commits reachable from HEAD, or 0 for a repo with no history."
  @spec commit_count(pid()) :: non_neg_integer()
  def commit_count(session) do
    counted = Session.run(session, "git rev-list --count HEAD")

    case Integer.parse(String.trim(counted.stdout)) do
      {n, _} -> n
      :error -> 0
    end
  end

  @doc """
  Last 3 commit subjects and the first 5 files changed in HEAD, for the
  session-open tree view.
  """
  @spec recent_history(pid()) :: String.t()
  def recent_history(session) do
    log = Session.run(session, "git log --oneline -3 --no-decorate")

    files =
      Session.run(
        session,
        "git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null | head -5"
      )

    lines = ["recent commits:"]

    lines =
      if log.exit_code == 0 and String.trim(log.stdout) != "" do
        lines ++ Enum.map(String.split(String.trim(log.stdout), "\n"), &("  " <> &1))
      else
        lines
      end

    lines =
      if files.exit_code == 0 and String.trim(files.stdout) != "" do
        lines ++
          ["", "files in HEAD:"] ++
          Enum.map(String.split(String.trim(files.stdout), "\n"), &("  " <> &1))
      else
        lines
      end

    Enum.join(lines, "\n")
  end
end
