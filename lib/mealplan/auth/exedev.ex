defmodule Mealplan.Auth.Exedev do
  @moduledoc """
  The whole of this product's coupling to exe.dev, in one module so it is one
  grep. Ported from `src/auth/exedev.ts`. See ADR 0009.

  exe.dev terminates TLS at the edge and adds two headers for an authenticated
  user: `X-ExeDev-UserID` (a stable id) and `X-ExeDev-Email`. They are present
  only when the user is authenticated. There is no OIDC endpoint — headers are
  the entire interface.
  """

  @prefix "/__exe.dev/"
  def prefix, do: @prefix

  @email_header "x-exedev-email"
  @user_id_header "x-exedev-userid"

  @type identity :: %{email: String.t(), user_id: String.t() | nil}

  @doc "The identity exe.dev asserts for this `Plug.Conn`, or nil."
  @spec identity_of(Plug.Conn.t()) :: identity() | nil
  def identity_of(conn) do
    case single(Plug.Conn.get_req_header(conn, @email_header)) do
      nil -> nil
      email -> %{email: email, user_id: single(Plug.Conn.get_req_header(conn, @user_id_header))}
    end
  end

  @doc """
  Where to send a browser that carries no identity. `return_to` must be a path
  on this same host — an absolute URL would be an open redirect through our own
  login link.
  """
  def login_redirect(return_to) do
    path =
      if is_binary(return_to) and String.starts_with?(return_to, "/") and
           not String.starts_with?(return_to, "//"),
         do: return_to,
         else: "/"

    "#{@prefix}login?redirect=#{URI.encode_www_form(path)}"
  end

  @doc "Case-insensitive comparison for \"is this the household\"."
  def same_email?(one, other) do
    String.downcase(String.trim(one || "")) == String.downcase(String.trim(other || ""))
  end

  defp single([value | _]) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp single(_), do: nil
end
