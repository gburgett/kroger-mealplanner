defmodule MealplanWeb.Plugs.ExedevGate do
  @moduledoc """
  Let the household through, and nobody else. Ported from `householdOnly` in
  `src/mcp/server.ts`.

  This is the only thing in the product that exe.dev authentication guards, and
  it guards it because it is the only thing a person opens in a browser:
  `/authorize`, `/consent` and (later) `/kroger/*`. The OAuth endpoints an MCP
  client uses — `/register`, `/token`, `/revoke`, `/.well-known/*` — stay open,
  because a client has no browser and could never get a first credential
  otherwise (ADR 0009).

  Three answers, each naming what it saw:

    * no identity      -> 302 to the exe.dev login, told to come back here
    * another account  -> 403, naming both emails
    * the household    -> `conn.assigns.identity`, and on
  """

  import Plug.Conn

  alias Mealplan.Accounts
  alias Mealplan.Auth.Exedev
  alias MealplanWeb.ConsentPage

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      String.starts_with?(conn.request_path, Exedev.prefix()) ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "that path belongs to exe.dev\n")
        |> halt()

      true ->
        gate(conn, Exedev.identity_of(conn))
    end
  end

  defp gate(conn, nil) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("location", Exedev.login_redirect(original_url(conn)))
    |> send_resp(302, "")
    |> halt()
  end

  defp gate(conn, %{email: email} = identity) do
    if Accounts.owner?(Mealplan.Config.tenant(), email) do
      assign(conn, :identity, identity)
    else
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("text/html")
      |> send_resp(403, ConsentPage.not_the_household(email, Mealplan.Config.owner()))
      |> halt()
    end
  end

  defp original_url(conn) do
    case conn.query_string do
      "" -> conn.request_path
      qs -> conn.request_path <> "?" <> qs
    end
  end
end
