defmodule Mealplan.Repo do
  @moduledoc """
  Server state: registered OAuth clients, codes in flight, tokens, and the
  household's Kroger credential. Never the corpus — the folder is the database
  for anything a person would want to read (AGENTS.md).

  PostgreSQL (ADR 0028). ADR 0024 had moved this to one SQLite file, and the
  reasons it gave are all still true; what changed is the constraint around
  them. The SuperTokens core that authenticates the household (ADR 0027)
  accepts PostgreSQL and nothing else, so a server runs on this VM either way,
  and a second datastore beside it would buy nothing but a second backup to
  forget.

  The two databases in that server are `mealplan` (this) and `supertokens`
  (the core). They share a process and a backup. They share no table.

  The state is outside the meal-plan folder by construction: a connection
  string does not name a path inside the sandbox mount. `Mealplan.Boot` used to
  check that, and the check is deleted rather than maintained.
  """

  use Ecto.Repo,
    otp_app: :mealplan,
    adapter: Ecto.Adapters.Postgres
end
