defmodule Mealplan.Repo do
  @moduledoc """
  Server state: registered OAuth clients, codes in flight, tokens, and the
  household's Kroger credential. Never the corpus — the folder is the database
  for anything a person would want to read (AGENTS.md).

  SQLite, in one file (ADR 0024, restored by ADR 0030). One household on one
  machine has one writer, and the file is easier to back up, to move and to
  reason about than a server. ADR 0028 had moved this to PostgreSQL, but only
  because a self-hosted SuperTokens core accepted no other database; ADR 0029
  moved the core to the managed service, which brings its own database, so the
  reason was spent and the state came back to a file.

  Since ADR 0038 it also holds every household's meal plan. An agent reaches
  only its own household's documents through the tools; nothing reaches the
  other tables, including the household's Kroger refresh token, which is
  stored in the clear because a hash cannot go in an Authorization header.
  """

  use Ecto.Repo,
    otp_app: :mealplan,
    adapter: Ecto.Adapters.SQLite3
end
