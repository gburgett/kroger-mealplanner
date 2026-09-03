defmodule Mealplan.Git.Commit do
  @moduledoc """
  The identity and clock the server commits under, and the git-date format.
  Ported from `src/git/commit.ts` and `src/git/repository.ts`.

  Like everything in `Mealplan.Git`, the commits themselves run INSIDE the
  sandbox (see `Mealplan.Sandbox.Session`): the bind includes `.git`, so an
  agent can plant a hook or a clean filter there and git would run it. Running
  git in the sandbox puts those back inside the boundary.
  """

  @committer_name "Meal Planner"
  @committer_email "meal-planner@localhost"
  @first_commit_message "Initialise the meal plan folder"

  def committer_name, do: @committer_name
  def committer_email, do: @committer_email
  def first_commit_message, do: @first_commit_message

  @doc "Git wants RFC 2822 or ISO 8601. ISO with an offset is unambiguous."
  @spec git_date(DateTime.t()) :: String.t()
  def git_date(%DateTime{} = at) do
    at
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S +0000")
  end

  @spec commit_environment(DateTime.t()) :: %{String.t() => String.t()}
  def commit_environment(%DateTime{} = at) do
    stamp = git_date(at)

    %{
      "GIT_AUTHOR_NAME" => @committer_name,
      "GIT_AUTHOR_EMAIL" => @committer_email,
      "GIT_AUTHOR_DATE" => stamp,
      "GIT_COMMITTER_NAME" => @committer_name,
      "GIT_COMMITTER_EMAIL" => @committer_email,
      "GIT_COMMITTER_DATE" => stamp
    }
  end

  @doc "Single-quote for bash. The only safe way to put agent text on a command line."
  def quote_arg(text) do
    "'" <> String.replace(to_string(text), "'", "'\\''") <> "'"
  end
end
