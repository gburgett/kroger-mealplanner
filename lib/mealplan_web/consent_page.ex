defmodule MealplanWeb.ConsentPage do
  @moduledoc """
  The consent page: the one screen in this product a person ever looks at, and
  the "not the household" page beside it. Ported from `src/auth/consent.ts`.
  Themed to match `MealplanWeb.SitePages` and `MealplanWeb.LoginPage`
  (`MealplanWeb.Theme`) as part of the Plantrify rebrand.

  Everything interpolated here is attacker-controlled — `client_name`,
  `client_uri` and the scopes all come from the open registration endpoint. The
  app is generated `--no-html`, so there is no EEx auto-escaping to lean on;
  `e/1` below is the same five-character escape `src/auth/consent.ts` carried,
  for the same reason it carried it — a template engine running outside the
  sandbox in the process that holds the household's tokens is a bad trade for
  two paragraphs of markup. The redirect URI is shown as text, not as a link.
  """

  alias MealplanWeb.Theme

  @doc """
  `opts` keys: `:consent_id`, `:client` (map), `:params` (map), `:phone`,
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
    #{Theme.fonts()}
    <style>
    #{Theme.css()}
    body { display: flex; align-items: center; justify-content: center; min-height: 100vh; padding: 1.5rem; }
    .card { width: 100%; max-width: 30rem; }
    h1 { font-size: 1.6rem; line-height: 1.3; margin: 0 0 1.25rem; }
    dl { display: grid; grid-template-columns: max-content 1fr; gap: .4rem 1rem; margin: 1.5rem 0; font-size: .95rem; }
    dt { color: var(--label); }
    dd { margin: 0; overflow-wrap: anywhere; color: var(--ink-soft); }
    .warn { background: var(--warn-bg); border-left: 3px solid var(--warn-border); padding: .85rem 1.1rem; color: var(--ink-soft); }
    form { margin-top: 2rem; }
    .actions { display: flex; gap: .75rem; margin-top: 1.5rem; }
    button { font: 500 15px/1 system-ui, sans-serif; padding: .8rem 1.4rem; border-radius: 4px; border: 1px solid var(--border); background: #fff; color: var(--ink); cursor: pointer; }
    button.approve { background: var(--green); border-color: var(--green); color: #f7fbf8; }
    button.approve:hover { background: var(--green-dark); }
    .quiet { color: var(--label); font-size: .9rem; }
    </style>
    </head>
    <body>
    <div class="card">
    <h1>Let <strong>#{e(name)}</strong> into the meal plan?</h1>

    <p class="warn">Approving gives this program a shell over your meal-plan folder:
    it can read, change and delete every recipe and every meal. Everything it does
    is committed, so it can be undone — but only if you notice.</p>

    <dl>
      <dt>Signed in as</dt><dd>#{e(opts[:phone])}</dd>
      <dt>Folder</dt><dd><code>#{e(opts[:folder])}</code></dd>
      <dt>Client id</dt><dd><code>#{e(client["client_id"])}</code></dd>
    #{website}  <dt>Sends you back to</dt><dd><code>#{e(params["redirect_uri"])}</code></dd>
      <dt>Asking for</dt><dd>#{scopes_text}</dd>
    </dl>

    <p>If you did not just add this server to an assistant, close this page.</p>

    <form method="post" action="/consent">
      <input type="hidden" name="consent_id" value="#{e(opts[:consent_id])}">
    #{kroger}  <div class="actions">
        <button type="submit" name="decision" value="approve" class="approve">Approve</button>
        <button type="submit" name="decision" value="deny">Deny</button>
      </div>
    </form>
    </div>
    </body>
    </html>
    """
  end

  @doc """
  A page for a telephone that holds a session this server issued but owns no
  tenant (ADR 0033) — a revoked invitation, or a redemption that did not finish.

  It names no other household: there is nothing here that is anyone else's.
  """
  def owns_no_tenant(phone) do
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>No meal plan for this number</title>
    #{Theme.fonts()}
    <style>
    #{Theme.css()}
    body { display: flex; align-items: center; justify-content: center; min-height: 100vh; padding: 1.5rem; }
    .card { width: 100%; max-width: 28rem; }
    h1 { font-size: 1.5rem; line-height: 1.3; margin: 0 0 1rem; }
    p { color: var(--ink-soft); }
    button { font: 500 15px/1 system-ui, sans-serif; padding: .7rem 1.2rem; border-radius: 4px; border: 1px solid var(--border); background: #fff; color: var(--ink); cursor: pointer; }
    </style>
    </head>
    <body>
    <div class="card">
    <h1>There is no meal plan for this number</h1>
    <p>You are signed in as <strong>#{e(phone)}</strong>, but this number does
    not own a meal plan. An invitation may have been withdrawn.</p>
    <p>Ask whoever runs the meal planner to invite this number, then sign in again:
    <form method="post" action="/logout"><button type="submit">Sign out</button></form>
    </p>
    </div>
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
