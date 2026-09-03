defmodule MealplanWeb.ConsentPage do
  @moduledoc """
  The consent page: the one screen in this product a person ever looks at, and
  the "not the household" page beside it. Ported from `src/auth/consent.ts`.

  Everything interpolated here is attacker-controlled — `client_name`,
  `client_uri` and the scopes all come from the open registration endpoint. The
  app is generated `--no-html`, so there is no EEx auto-escaping to lean on;
  `e/1` below is the same five-character escape `src/auth/consent.ts` carried,
  for the same reason it carried it — a template engine running outside the
  sandbox in the process that holds the household's tokens is a bad trade for
  two paragraphs of markup. The redirect URI is shown as text, not as a link.
  """

  @doc """
  `opts` keys: `:consent_id`, `:client` (map), `:params` (map), `:email`,
  `:folder`, `:offer_kroger` (bool), `:kroger_connected` (bool).
  """
  def render(opts) do
    client = opts[:client]
    params = opts[:params]
    name = presence(client["client_name"]) || client["client_id"]
    scopes = params["scopes"] || []

    scopes_text =
      if scopes == [], do: "no named scopes", else: e(Enum.join(scopes, ", "))

    website =
      case presence(client["client_uri"]) do
        nil -> ""
        uri -> "  <dt>Website</dt><dd>#{e(uri)}</dd>\n"
      end

    kroger =
      if opts[:offer_kroger] do
        again = if opts[:kroger_connected], do: " again", else: ""

        """
        <p><label>
          <input type="checkbox" name="connect_kroger" value="yes">
          Also connect my Kroger account#{again}, and choose which store I shop at
        </label></p>
        <p class="quiet">Kroger's own sign-in opens next. The meal planner can only ADD
        to your cart — there is no way for it to place an order, so no money moves until
        you open the Kroger app yourself.</p>
        """
      else
        ""
      end

    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Let #{e(name)} into the meal plan?</title>
    <style>
      body { font: 16px/1.6 system-ui, sans-serif; max-width: 34rem; margin: 4rem auto; padding: 0 1rem; color: #1a1a1a; }
      h1 { font-size: 1.4rem; line-height: 1.3; }
      dl { display: grid; grid-template-columns: max-content 1fr; gap: .35rem 1rem; margin: 1.5rem 0; }
      dt { color: #666; }
      dd { margin: 0; overflow-wrap: anywhere; }
      code { background: #f2f2f2; padding: .1rem .3rem; border-radius: 3px; }
      .warn { background: #fff8e5; border-left: 3px solid #e0a800; padding: .75rem 1rem; }
      form { margin-top: 2rem; }
      button { font: inherit; padding: .6rem 1.4rem; border-radius: 5px; border: 1px solid #bbb; cursor: pointer; margin-right: .75rem; }
      button.approve { background: #1a6b3c; border-color: #1a6b3c; color: #fff; }
      .quiet { color: #666; font-size: .9rem; }
    </style>
    </head>
    <body>
    <h1>Let <strong>#{e(name)}</strong> into the meal plan?</h1>

    <p class="warn">Approving gives this program a shell over your meal-plan folder:
    it can read, change and delete every recipe and every meal. Everything it does
    is committed, so it can be undone — but only if you notice.</p>

    <dl>
      <dt>Signed in as</dt><dd>#{e(opts[:email])}</dd>
      <dt>Folder</dt><dd><code>#{e(opts[:folder])}</code></dd>
      <dt>Client id</dt><dd><code>#{e(client["client_id"])}</code></dd>
    #{website}  <dt>Sends you back to</dt><dd><code>#{e(params["redirect_uri"])}</code></dd>
      <dt>Asking for</dt><dd>#{scopes_text}</dd>
    </dl>

    <p>If you did not just add this server to an assistant, close this page.</p>

    <form method="post" action="/consent">
      <input type="hidden" name="consent_id" value="#{e(opts[:consent_id])}">
    #{kroger}  <button type="submit" name="decision" value="approve" class="approve">Approve</button>
      <button type="submit" name="decision" value="deny">Deny</button>
    </form>
    </body>
    </html>
    """
  end

  @doc "A page for a person who is signed in to exe.dev, but is not the household."
  def not_the_household(saw, owner) do
    """
    <!doctype html>
    <html lang="en">
    <head><meta charset="utf-8"><title>Not your meal plan</title>
    <style>body { font: 16px/1.6 system-ui, sans-serif; max-width: 34rem; margin: 4rem auto; padding: 0 1rem; }</style>
    </head>
    <body>
    <h1>This meal plan is not yours</h1>
    <p>exe.dev says you are signed in as <strong>#{e(saw)}</strong>.
    This meal plan belongs to <strong>#{e(owner)}</strong>, and only that
    account can let a program into it.</p>
    <p>If you have more than one exe.dev account, sign out and sign in as the owner:
    <form method="post" action="/__exe.dev/logout"><button type="submit">Sign out of exe.dev</button></form>
    </p>
    </body>
    </html>
    """
  end

  # The five that matter in an HTML body and in a double-quoted attribute.
  defp e(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp presence(_), do: nil
end
