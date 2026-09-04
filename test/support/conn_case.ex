defmodule MealplanWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test.

  Do NOT set `async: true` here. The database is SQLite (ADR 0024) and takes
  one writer at a time, and the suite is single-tenant by construction anyway —
  a scenario points `Mealplan.Config` at its own folder while it runs (ADR 0022).
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint MealplanWeb.Endpoint

      use MealplanWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import MealplanWeb.ConnCase
    end
  end

  setup tags do
    Mealplan.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
