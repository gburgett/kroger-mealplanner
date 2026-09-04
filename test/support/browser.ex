defmodule Mealplan.Browser do
  @moduledoc """
  A person at a keyboard, stood in for. A port of the browser half of
  `features/support/world.ts`.

  The consent page and the `/kroger` screens are the only two flows in this
  product that need a browser and a human (ADR 0009, ADR 0010), so they are the
  only two the scenarios walk this way. It is a real request over a real socket
  to the endpoint this BEAM is running: the exe.dev gate, the router, the
  controllers, the redirects and the form encoding are all the real ones.

  ADR 0022 moved the tool scenarios in process and recorded what that cost —
  the authorisation server was no longer exercised by any scenario. This is how
  that debt is paid for the screens: they are still driven through HTTP.

  Redirects are never followed. Where a redirect goes IS the assertion in most
  of these scenarios, and following one would hide it.
  """

  @doc "The identity headers exe.dev adds for a signed-in person. See `Mealplan.Auth.Exedev`."
  def signed_in(email, user_id \\ nil) do
    [
      {"x-exedev-email", email},
      {"x-exedev-userid", user_id || "exedev-#{:erlang.phash2(email)}"}
    ]
  end

  @doc "Nobody is signed in: exe.dev adds no headers at all."
  def anonymous, do: []

  @doc "GET `path`, without following the redirect."
  def get(path, headers \\ []), do: request(:get, path, headers, nil)

  @doc """
  POST a form to `path`, without following the redirect.

  `form` is a map or keyword list, encoded as `application/x-www-form-urlencoded`
  — what a browser sends, and what the controllers parse.
  """
  def post(path, form, headers \\ []), do: request(:post, path, headers, {:form, form})

  @doc "POST a JSON body. Dynamic client registration is the one caller."
  def post_json(path, body, headers \\ []), do: request(:post, path, headers, {:json, body})

  @doc "GET an absolute URL — the hop to Kroger's sign-in, which is another host."
  def get_url(url, headers \\ []) do
    run(Req.new(method: :get, url: url, headers: headers))
  end

  defp request(method, path, headers, body) do
    options =
      [method: method, url: base() <> path, headers: headers]
      |> then(fn opts ->
        case body do
          nil -> opts
          {:form, form} -> Keyword.put(opts, :form, form)
          {:json, json} -> Keyword.put(opts, :json, json)
        end
      end)

    run(Req.new(options))
  end

  defp run(request) do
    {:ok, response} =
      request
      |> Req.Request.put_new_option(:redirect, false)
      |> Req.Request.put_new_option(:retry, false)
      |> Req.Request.put_new_option(:decode_body, false)
      |> Req.request()

    %{
      status: response.status,
      body: to_string(response.body),
      location: response |> Req.Response.get_header("location") |> List.first(),
      session_id: response |> Req.Response.get_header("mcp-session-id") |> List.first(),
      www_authenticate:
        response |> Req.Response.get_header("www-authenticate") |> List.first()
    }
  end

  @doc "Where this BEAM's endpoint is answering. The OAuth issuer is the same string."
  def base, do: Mealplan.Config.public_url()
end
