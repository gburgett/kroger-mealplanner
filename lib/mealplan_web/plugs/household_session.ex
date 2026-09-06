defmodule MealplanWeb.Plugs.HouseholdSession do
  @moduledoc """
  Let an invited household through, and nobody else. Replaces
  `MealplanWeb.Plugs.ExedevGate`, which read an exe.dev header. See ADR 0027 and
  ADR 0033.

  The header gate was worth what the network boundary around the VM's subnet
  was worth, and `docs/exedev-identity-header-study.md` records that nobody
  documented that boundary: anything that can route to `10.42.0.0/16` reaches
  the port with no proxy in front of it, and therefore with whatever headers it
  cares to send. A cookie this server signed does not have that hole, because
  the signature does not depend on how the request arrived.

  Three answers:

    * no session           -> 302 to `/login`, told to come back here
    * a session, owns no tenant -> 403, naming no other household
    * a session, owns a tenant  -> `conn.assigns.identity` (`%{phone:, user:}`)
      and `conn.assigns.tenant` (the slug), and on

  Identity is the telephone number now, not an email (ADR 0033). The tenant is
  resolved from the user's owner membership, so a request carries its own
  household rather than sharing one global answer.
  """

  import Plug.Conn

  alias Mealplan.{Accounts, Tenancy}

  # How long a session lasts before the household types a code again. Long
  # enough that planning a week of dinners is not interrupted; short enough
  # that a browser left open in a kitchen is not a standing invitation.
  @max_age_seconds 14 * 24 * 60 * 60

  def init(opts), do: opts

  def call(conn, _opts), do: gate(conn, identity_of(conn))

  @doc """
  The identity this server issued for the request, or nil.

  Public because `MealplanWeb.LoginController` asks the same question to decide
  whether a signed-in household even needs the login page. A returned identity
  means "this server issued this session" — it does NOT mean the person owns a
  tenant; `call/2` checks that separately.
  """
  @spec identity_of(Plug.Conn.t()) :: %{phone: String.t(), user: struct()} | nil
  def identity_of(conn) do
    with phone when is_binary(phone) <- get_session(conn, :user_phone),
         signed_at when is_integer(signed_at) <- get_session(conn, :signed_in_at),
         false <- expired?(signed_at),
         user when not is_nil(user) <- Accounts.get_user(phone) do
      %{phone: user.phone, user: user}
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
    |> put_session(:user_phone, user.phone)
    |> put_session(:signed_in_at, System.system_time(:second))
  end

  @doc "Drop the session. Everything in it, not only the user."
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

  defp gate(conn, %{phone: phone} = identity) do
    case Tenancy.tenant_for_phone(phone) do
      %{slug: slug} ->
        conn
        |> assign(:identity, Map.put(identity, :tenant, slug))
        |> assign(:tenant, slug)

      nil ->
        # A session this server issued, for a telephone that owns nothing: an
        # invitation revoked, or a code spent before its redemption finished.
        # The refusal names no other household — there is nothing here that is
        # anyone else's to name.
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_content_type("text/html")
        |> send_resp(403, MealplanWeb.ConsentPage.owns_no_tenant(phone))
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
