defmodule MealplanWeb.LoginPage do
  @moduledoc """
  The two login screens: ask for a telephone number, then ask for the code that
  arrived. See ADR 0027. Themed to match `MealplanWeb.SitePages` and
  `MealplanWeb.ConsentPage` (`MealplanWeb.Theme`) as part of the Plantrify
  rebrand — the household should not land on a different-looking site between
  the invitation and the sign-in.

  Written the same way as `MealplanWeb.ConsentPage`, and for the same reason:
  the app is generated `--no-html`, so there is no EEx auto-escaping to lean
  on, and `e/1` is the same five-character escape. A template engine running
  outside the sandbox in the process that holds the household's tokens is a bad
  trade for two forms.

  **The code is never rendered here.** It exists in the message and in the
  household's hand. `code_form/1` takes no code argument, so there is no
  parameter for one to arrive through by mistake.
  """

  alias MealplanWeb.Theme

  @doc """
  The first screen. `opts` keys: `:return_to`, `:error`, `:phone`.

  There is no "not configured" state any more (ADR 0033): the allowlist is the
  `invitations` table, not an environment variable, so the page is always
  usable. A number with no invitation gets the same answer a real send gets —
  see `Mealplan.Auth.Otp.start/1`.

  The Terms of Service / Privacy Policy checkbox is required on every visit to
  this form, not only a household's first one: nothing before a code is
  checked can tell a new household from a returning one without the answer
  itself becoming an oracle for whether a number is invited
  (`MealplanWeb.LoginController.send_code/2` enforces this server-side too, so
  the check cannot be skipped by posting the form directly).
  """
  def phone_form(opts \\ []) do
    error = banner(opts[:error])

    body = """
    #{error}
    <form method="post" action="/login">
      <input type="hidden" name="return_to" value="#{e(opts[:return_to] || "/")}">
      <p>
        <label for="phone">Your telephone number</label>
        <input id="phone" name="phone" type="tel" autocomplete="tel"
               inputmode="tel" placeholder="+1 509 555 0142"
               value="#{e(opts[:phone] || "")}" required autofocus>
      </p>
      <p class="agree">
        <label>
          <input type="checkbox" name="agreed_to_terms" value="yes" required>
          I have read and agree to the
          <a href="/terms.html" target="_blank" rel="noopener">Terms of Service</a>
          and <a href="/privacy.html" target="_blank" rel="noopener">Privacy Policy</a>.
        </label>
      </p>
      <p><button type="submit" class="btn">Send me a code</button></p>
    </form>
    <p class="quiet">A six-digit code arrives as a text message. It works once,
    and it expires in a few minutes.</p>
    """

    page("Sign in to the meal plan", """
    <h1>Sign in to the meal plan</h1>
    #{body}
    """)
  end

  @doc """
  The second screen. `opts` keys: `:return_to`, `:error`, `:phone`.

  `:phone` is shown with all but the last four digits replaced, so the person
  can tell which telephone to look at without the page publishing the number to
  anyone who reaches it.
  """
  def code_form(opts \\ []) do
    error = banner(opts[:error])

    where =
      case opts[:phone] do
        nil -> "your telephone"
        phone -> "the telephone ending #{e(last_four(phone))}"
      end

    page("Enter your code", """
    <h1>Enter your code</h1>
    <p>We sent a six-digit code to #{where}.</p>
    #{error}
    <form method="post" action="/login/code">
      <input type="hidden" name="return_to" value="#{e(opts[:return_to] || "/")}">
      <p>
        <label for="code">The code</label>
        <input id="code" name="code" type="text" inputmode="numeric"
               autocomplete="one-time-code" pattern="[0-9]*" maxlength="6"
               required autofocus>
      </p>
      <p><button type="submit" class="btn">Sign in</button></p>
    </form>
    <form method="post" action="/login">
      <input type="hidden" name="return_to" value="#{e(opts[:return_to] || "/")}">
      <input type="hidden" name="phone" value="#{e(opts[:phone] || "")}">
      <p><button type="submit" class="quiet-button">Send a new code</button></p>
    </form>
    """)
  end

  @doc "Shown after a sign-out, so the household knows it worked."
  def signed_out do
    page("Signed out", """
    <h1>Signed out</h1>
    <p>You are signed out of the meal plan.</p>
    <p><a href="/login">Sign in again</a></p>
    """)
  end

  defp banner(nil), do: ""
  defp banner(message), do: ~s(<p class="error">#{e(message)}</p>\n)

  defp last_four(phone) do
    case String.length(phone) do
      n when n >= 4 -> String.slice(phone, -4, 4)
      _ -> phone
    end
  end

  defp page(title, inner) do
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>#{e(title)}</title>
    #{Theme.fonts()}
    <style>
    #{Theme.css()}
    body { display: flex; align-items: center; justify-content: center; min-height: 100vh; padding: 1.5rem; }
    .card { width: 100%; max-width: 26rem; }
    h1 { font-size: 1.6rem; line-height: 1.25; margin: 0 0 1.5rem; }
    label { display: block; margin-bottom: .4rem; font: 500 12.5px/1 system-ui, sans-serif; letter-spacing: .01em; }
    input[type=tel], input[type=text] {
      font: 300 16px/1.5 'Newsreader', Georgia, serif;
      padding: .65rem .7rem;
      width: 100%;
      max-width: 20rem;
      box-sizing: border-box;
      background: #fff;
      border: 1px solid var(--border);
      border-radius: 3px;
      color: var(--ink);
    }
    input:focus { outline: 2px solid var(--green); outline-offset: 1px; }
    .agree label { display: flex; align-items: flex-start; gap: .5rem; font: 300 14px/1.5 'Newsreader', Georgia, serif; color: var(--ink-soft); cursor: pointer; }
    .agree input[type=checkbox] { margin-top: .2rem; flex: none; }
    .agree a { color: var(--green); text-decoration: underline; }
    .quiet, .quiet-button { color: var(--label); font-size: .9rem; }
    .quiet-button { background: none; border: none; padding: 0; text-decoration: underline; cursor: pointer; font-family: inherit; }
    .error { color: var(--error); font-weight: 600; }
    </style>
    </head>
    <body>
    <div class="card">
    #{inner}
    </div>
    </body>
    </html>
    """
  end

  defp e(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
