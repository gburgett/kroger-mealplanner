defmodule MealplanWeb.Plugs.BearerAuth do
  @moduledoc """
  The bearer gate on `/mcp`. Ported from the SDK's `requireBearerAuth`, kept as
  our own Plug because the token model is opaque-in-store: neither `anubis_mcp`
  nor any introspection endpoint is involved, `Mealplan.Auth.Provider` verifies
  the token against the Ecto store directly.

  On failure it emits the `WWW-Authenticate: Bearer ... resource_metadata="…"`
  challenge the pinned TypeScript SDK client parses to start its OAuth dance,
  and a `401` with an RFC 6750 JSON body.
  """

  import Plug.Conn

  alias Mealplan.Auth.Provider

  def init(opts), do: opts

  def call(conn, _opts) do
    case token(conn) do
      {:ok, raw} ->
        case Provider.verify_access_token(raw) do
          {:ok, info} ->
            conn
            |> assign(:auth, info)
            |> assign(:tenant, info.tenant)

          {:error, message} ->
            unauthorised(conn, message)
        end

      {:error, message} ->
        unauthorised(conn, message)
    end
  end

  defp token(conn) do
    case get_req_header(conn, "authorization") do
      [header | _] ->
        case String.split(header, " ", parts: 2) do
          [scheme, value] ->
            if String.downcase(scheme) == "bearer" and value != "",
              do: {:ok, value},
              else: {:error, "Invalid Authorization header format, expected 'Bearer TOKEN'"}

          _ ->
            {:error, "Invalid Authorization header format, expected 'Bearer TOKEN'"}
        end

      [] ->
        {:error, "Missing Authorization header"}
    end
  end

  defp unauthorised(conn, message) do
    challenge =
      ~s(Bearer error="invalid_token", error_description="#{message}", ) <>
        ~s(resource_metadata="#{resource_metadata_url()}")

    body = Jason.encode!(%{error: "invalid_token", error_description: message})

    conn
    |> put_resp_header("www-authenticate", challenge)
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end

  defp resource_metadata_url do
    Mealplan.Config.public_url()
    |> String.trim_trailing("/")
    |> Kernel.<>("/.well-known/oauth-protected-resource/mcp")
  end
end
