defmodule MealplanWeb.LoginPage do
  @moduledoc """
  The two login screens: ask for a telephone number, then ask for the code that
  arrived. See ADR 0027.

  Written the same way as `MealplanWeb.ConsentPage`, and for the same reason:
  the app is generated `--no-html`, so there is no EEx auto-escaping to lean
  on, and `e/1` is the same five-character escape. A template engine running
  outside the sandbox in the process that holds the household's tokens is a bad
  trade for two forms.

  **The code is never rendered here.** It exists in the message and in the
  household's hand. `code_form/1` takes no code argument, so there is no
  parameter for one to arrive through by mistake.
  """

  @doc """
  The first screen. `opts` keys: `:return_to`, `:error`, `:configured` (bool).
  """
  def phone_form(opts \\ []) do
    error = banner(opts[:error])

    body =
      if opts[:configured] == false do
        """
        <p class="error">Nobody can sign in yet.</p>
        <p class="quiet">The server has no household telephone number, so it has
        nothing to send a code to. Whoever runs this machine sets
        <code>MEALPLAN_OWNER_PHONE</code> and restarts the meal planner. The
        journal line that starts <code>sign-in:</code> says what is missing.</p>
        """
      else
        """
        #{error}
        <form method="post" action="/login">
          <input type="hidden" name="return_to" value="#{e(opts[:return_to] || "/")}">
          <p>
            <label for="phone">Your telephone number</label><br>
            <input id="phone" name="phone" type="tel" autocomplete="tel"
                   inputmode="tel" placeholder="+1 509 555 0142" required autofocus>
          </p>
          <p><button type="submit">Send me a code</button></p>
        </form>
        <p class="quiet">A six-digit code arrives as a text message. It works once,
        and it expires in a few minutes.</p>
        """
      end

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
        <label for="code">The code</label><br>
        <input id="code" name="code" type="text" inputmode="numeric"
               autocomplete="one-time-code" pattern="[0-9]*" maxlength="6"
               required autofocus>
      </p>
      <p><button type="submit">Sign in</button></p>
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
    <style>
      body { font: 16px/1.6 system-ui, sans-serif; max-width: 34rem; margin: 4rem auto; padding: 0 1rem; color: #1a1a1a; }
      h1 { font-size: 1.4rem; line-height: 1.3; }
      input[type=tel], input[type=text] { font: inherit; padding: .5rem; width: 100%; max-width: 18rem; box-sizing: border-box; }
      button { font: inherit; padding: .5rem 1rem; cursor: pointer; }
      .quiet, .quiet-button { color: #555; font-size: .9rem; }
      .quiet-button { background: none; border: none; padding: 0; text-decoration: underline; }
      .error { color: #a11; font-weight: 600; }
      code { background: #f2f2f2; padding: .1rem .3rem; }
    </style>
    </head>
    <body>
    #{inner}
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
