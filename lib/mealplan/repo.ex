defmodule Mealplan.Repo do
  @moduledoc """
  Server state: registered OAuth clients, codes in flight, tokens, and the
  household's Kroger credential. Never the corpus — the folder is the database
  for anything a person would want to read (AGENTS.md).

  SQLite, in one file (ADR 0024). One household on one machine has one writer,
  and the file is easier to back up, to move and to reason about than a server.
  The file must live OUTSIDE the meal-plan folder; `Mealplan.Boot` refuses to
  start when it does not, because the sandbox mounts that folder and an agent
  can read every byte of it.
  """

  use Ecto.Repo,
    otp_app: :mealplan,
    adapter: Ecto.Adapters.SQLite3
end
