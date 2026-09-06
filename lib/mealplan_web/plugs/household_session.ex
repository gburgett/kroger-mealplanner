defmodule MealplanWeb.Plugs.HouseholdSession do
  @moduledoc """
  Let the household through, and nobody else. Replaces
  `MealplanWeb.Plugs.ExedevGate`, which read an exe.dev header. See ADR 0027.

  The header gate was worth what the network boundary around the VM's subnet
  was worth, and `docs/exedev-identity-header-study.md` records that nobody
  documented that boundary: anything that can route to `10.42.0.0/16` reaches
  the port with no proxy in front of it, and therefore with whatever headers it
  cares to send. A cookie this server signed does not have that hole, because
  the signature does not depend on how the request arrived.

  Three answers, each naming what it saw, the same three the exe.dev gate gave:

    * no session      -> 302 to `/login`, told to come back here
    * not the household -> 403, naming both emails
    * the household   -> `conn.assigns.identity`, and on

  `conn.assigns.identity` keeps the shape the exe.dev gate assigned —
  `%{email:, user_id:}` — so `OAuthController` and `KrogerController` did not
  change when the thing behind it did.
  """

  import Plug.Conn

  alias Mealplan.Accounts
  alias MealplanWeb.ConsentPage

  # How long a session lasts before the household types a code again. Long
  # enough that planning a week of dinners is not interrupted; short enough
  # that a browser left open in a kitchen is not a standing invitation.
  @max_age_seconds 14 * 24 * 60 * 60

  def init(opts), do: opts

  def call(conn, _opts), do: gate(conn, identity_of(conn))

  @doc """
  The identity this server issued for the request, or nil.

  Public because `MealplanWeb.LoginController` asks the same question to decide
  whether a signed-in household even needs the login page.
  """
  @spec identity_of(Plug.Conn.t()) :: %{email: String.t(), user_id: term()} | nil
  def identity_of(conn) do
    with user_id when not is_nil(user_id) <- get_session(conn, :user_id),
         signed_at when is_integer(signed_at) <- get_session(conn, :signed_in_at),
         false <- expired?(signed_at),
         user when not is_nil(user) <- Accounts.get_user(user_id) do
      %{email: user.email, user_id: user.id}
    else
      _ -> nil
    end
  end

  @doc """
  Put `user` in the session, and rotate the session id.

  `renew_session/1` is the part that matters and the part that is easy to
  leave out: without it, a session id an attacker fixed in the browser before
  the sign-in is still valid after it.
  """
  @spec sign_in(Plug.Conn.t(), struct()) :: Plug.Conn.t()
  def sign_in(conn, user) do
    conn
    |> configure_session(renew: true)
    |> put_session(:user_id, user.id)
    |> put_session(:signed_in_at, System.system_time(:second))
  end

  @doc "Drop the session. Everything in it, not only the user id."
  @spec sign_out(Plug.Conn.t()) :: Plug.Conn.t()
  def sign_out(conn), do: configure_session(conn, drop: true)

  @doc """
  Where a browser should come back to after it signs in.

  Only a path on this host. An absolute URL here would be an open redirect
  through our own login link, and `//host` is an absolute URL that looks like a
  path.
  """
  @spec safe_return_to(String.t() | nil) :: String.t()
  def safe_return_to(path) do
    if is_binary(path) and String.starts_with?(path, "/") and not String.starts_with?(path, "//"),
      do: path,
      else: "/"
  end

  @doc "The login URL for a browser that was trying to reach `return_to`."
  @spec login_redirect(String.t()) :: String.t()
  def login_redirect(return_to),
    do: "/login?return_to=#{URI.encode_www_form(safe_return_to(return_to))}"

  defp gate(conn, nil) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("location", login_redirect(original_url(conn)))
    |> send_resp(302, "")
    |> halt()
  end

  defp gate(conn, %{email: email} = identity) do
    if Accounts.owner?(Mealplan.Config.tenant(), email) do
      assign(conn, :identity, identity)
    else
      # A session this server issued, for somebody who is not the owner of this
      # tenant. It cannot happen while one household has one telephone, and it
      # is answered anyway: the membership is what decides, not the cookie.
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("text/html")
      |> send_resp(403, ConsentPage.not_the_household(email, Mealplan.Config.owner()))
      |> halt()
    end
  end

  defp expired?(signed_at), do: System.system_time(:second) - signed_at > @max_age_seconds

  defp original_url(conn) do
    case conn.query_string do
      "" -> conn.request_path
      qs -> conn.request_path <> "?" <> qs
    end
  end
end
