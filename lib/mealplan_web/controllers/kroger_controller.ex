defmodule MealplanWeb.KrogerController do
  @moduledoc """
  The Kroger screens. Ported from `mountKroger` in `src/mcp/server.ts`.

  The second and last flow that needs a browser and a person, behind the same
  `MealplanWeb.Plugs.ExedevGate` as the consent page — `/kroger/callback`
  included, because Kroger redirects a top-level browser navigation and the
  exe.dev session is on it (ADR 0009 / ADR 0010).

  THE LINK HAPPENS BEFORE THE AUTHORISATION CODE. The pending consent is parked
  in `Mealplan.Kroger.LinkDesk` across the Kroger hop; the code is minted last,
  in `store_submit/2`, and spent at once.
  """

  use MealplanWeb, :controller

  alias Mealplan.Auth.Provider
  alias Mealplan.Kroger
  alias Mealplan.Kroger.LinkDesk
  alias MealplanWeb.KrogerPages

  # GET /kroger — link, relink, or change store.
  def index(conn, _params) do
    case kroger() do
      nil ->
        html_resp(conn, 200, KrogerPages.status_page(%{configured: false, connected: false, store: nil}))

      _api ->
        {:ok, session} = session()
        config = Kroger.Config.read(session)

        store =
          if config.store != "" do
            %{name: config.store, address: "", modality: config.modality}
          else
            nil
          end

        conn
        |> put_resp_header("cache-control", "no-store")
        |> html_resp(
          200,
          KrogerPages.status_page(%{
            configured: true,
            connected: Kroger.Store.connected?(tenant_id()),
            store: store
          })
        )
    end
  end

  # POST /kroger/connect — start a link with no client waiting, go to Kroger.
  def connect(conn, _params) do
    case kroger() do
      nil ->
        text_resp(conn, 409, not_configured_text())

      api ->
        link = LinkDesk.open(conn.assigns.identity, nil)

        conn
        |> put_resp_header("cache-control", "no-store")
        |> redirect_302(Kroger.Api.authorize_url(api, link.state || ""))
    end
  end

  # GET /kroger/callback — Kroger redirects here. Exchange the code, save it.
  def callback(conn, params) do
    case kroger() do
      nil ->
        text_resp(conn, 409, not_configured_text())

      api ->
        case LinkDesk.claim_state(to_string(params["state"] || "")) do
          nil ->
            # A state we did not issue, or one already spent. Both refused the
            # same way: nothing about this request is trusted.
            text_resp(
              conn,
              403,
              "that Kroger sign-in does not match one this meal planner started. " <>
                "Nothing has been changed. Open /kroger and start again.\n"
            )

          link ->
            complete_callback(conn, api, link, params)
        end
    end
  end

  defp complete_callback(conn, api, link, params) do
    refused = params["error"]
    code = to_string(params["code"] || "")

    cond do
      is_binary(refused) and refused != "" ->
        text_resp(
          conn,
          200,
          "Kroger did not complete the sign-in: #{refused}. Nothing has been " <>
            "changed. Open /kroger to try again.\n"
        )

      code == "" ->
        text_resp(conn, 400, "Kroger sent no code back.\n")

      true ->
        tokens = Kroger.Api.token_from_code(api, code)
        Kroger.Store.save(tenant_id(), tokens)

        conn
        |> put_resp_header("cache-control", "no-store")
        |> redirect_302("/kroger/store?link=#{URI.encode_www_form(link.id)}")
    end
  end

  # GET /kroger/store — a zip code, then the stores near it.
  def store(conn, params) do
    case kroger() do
      nil ->
        text_resp(conn, 409, not_configured_text())

      api ->
        asked = if is_binary(params["link"]), do: params["link"], else: ""
        link = if asked != "", do: LinkDesk.get(asked), else: LinkDesk.open(conn.assigns.identity, nil)

        case link do
          nil ->
            html_resp(conn, 400, KrogerPages.link_gone_page())

          link ->
            zip = params["zip"] |> to_string() |> String.trim()
            {stores, problem} = maybe_search(api, zip)

            conn
            |> put_resp_header("cache-control", "no-store")
            |> html_resp(
              200,
              KrogerPages.store_page(%{
                link_id: link.id,
                zip_code: zip,
                stores: stores,
                searched: zip != "",
                problem: problem
              })
            )
        end
    end
  end

  defp maybe_search(_api, ""), do: {[], nil}

  defp maybe_search(api, zip) do
    {Kroger.Api.locations_near(api, zip), nil}
  rescue
    error -> {[], Exception.message(error)}
  end

  # POST /kroger/store — write config/kroger.md, then mint the code if a client waits.
  def store_submit(conn, params) do
    case kroger() do
      nil ->
        text_resp(conn, 409, not_configured_text())

      api ->
        case LinkDesk.take(to_string(params["link"] || "")) do
          nil ->
            html_resp(conn, 400, KrogerPages.link_gone_page())

          link ->
            location_id = to_string(params["store"] || "")

            modality =
              if Kroger.Config.modality?(params["modality"]), do: params["modality"], else: "pickup"

            zip = to_string(params["zip"] || "")

            case store_named(api, location_id, zip) do
              nil ->
                html_resp(
                  conn,
                  400,
                  KrogerPages.store_page(%{
                    link_id: link.id,
                    zip_code: zip,
                    stores: [],
                    searched: true,
                    problem: "Kroger has no store #{location_id}. Search again."
                  })
                )

              chosen ->
                finish_store(conn, link, chosen, modality)
            end
        end
    end
  end

  defp finish_store(conn, link, chosen, modality) do
    {:ok, session} = session()

    Kroger.Config.write(
      session,
      now(),
      %{
        location_id: chosen.location_id,
        name: chosen.name,
        address: chosen.address,
        modality: modality
      },
      base_url()
    )

    # The code is minted last, and spent at once. With no consent waiting, this
    # was somebody changing their shop, and there is nowhere to go back.
    case link.consent do
      nil ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> html_resp(
          200,
          KrogerPages.linked_page(%{name: chosen.name, address: chosen.address, modality: modality})
        )

      consent ->
        case Provider.issue_code(
               consent.client,
               consent.params,
               consent.identity.email,
               Mealplan.Config.tenant()
             ) do
          {:ok, code} ->
            conn
            |> put_resp_header("cache-control", "no-store")
            |> redirect_302(
              with_query(consent.params["redirect_uri"], [{"code", code}], consent.params["state"])
            )

          {:error, message} ->
            text_resp(conn, 403, message <> "\n")
        end
    end
  end

  # POST /kroger/disconnect — forget the credential, reset the folder's half.
  def disconnect(conn, _params) do
    if kroger(), do: Kroger.Store.clear(tenant_id())
    {:ok, session} = session()
    Kroger.Config.write(session, now(), nil, base_url())

    conn
    |> put_resp_header("cache-control", "no-store")
    |> redirect_302("/kroger")
  end

  # --- helpers ------------------------------------------------------

  # One store, by id, from a search Kroger answered. NEVER FROM A FORM FIELD —
  # the name and address land in config/kroger.md, which has to say something
  # true.
  defp store_named(_api, "", _zip), do: nil
  defp store_named(_api, _id, ""), do: nil

  defp store_named(api, location_id, zip) do
    api
    |> Kroger.Api.locations_near(zip, 25)
    |> Enum.find(&(&1.location_id == location_id))
  end

  defp kroger, do: Kroger.Api.for_household()

  defp session, do: Mealplan.Sandbox.open(Mealplan.Config.tenant(), Mealplan.Config.folder())

  defp now, do: Mealplan.Clock.now()

  defp base_url, do: Mealplan.Config.public_url()

  defp tenant_id do
    case Mealplan.Accounts.get_tenant_by_slug(Mealplan.Config.tenant()) do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp html_resp(conn, status, body) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, body)
  end

  defp text_resp(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end

  defp redirect_302(conn, location) do
    conn
    |> put_resp_header("location", location)
    |> send_resp(302, "")
  end

  defp with_query(uri, pairs, state) do
    query = URI.encode_query(pairs ++ if(state, do: [{"state", state}], else: []))

    case URI.parse(uri) do
      %URI{query: nil} = u -> %{u | query: query}
      %URI{query: existing} = u -> %{u | query: existing <> "&" <> query}
    end
    |> URI.to_string()
  end

  defp not_configured_text do
    "this meal planner has no Kroger credentials, so it cannot connect an account. " <>
      "Whoever runs the server sets KROGER_CLIENT_ID, KROGER_CLIENT_SECRET and " <>
      "MEALPLAN_PUBLIC_URL. See docs/deploying-behind-exe-dev.md.\n"
  end
end
