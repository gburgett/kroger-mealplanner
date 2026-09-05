defmodule MealplanWeb.LoginController do
  @moduledoc """
  The household's sign-in screens. See ADR 0027.

  These paths are OPEN at the proxy, for the same reason `/register` and
  `/token` are open (ADR 0009): a gate in front of the way in is a locked door
  with the key inside. What protects them is not a gate but an allowlist —
  `Mealplan.Auth.Otp.start/1` refuses every number that is not the household's,
  before the core is called and before a message costs anything.

  The login in flight lives in the signed session, not in the database. It
  holds no code: only `preAuthSessionId` and `deviceId`, which are worth
  nothing without the code that arrived on the telephone. That also means a
  restart of the server does not strand a household mid-login the way a
  process-memory table would.
  """

  use MealplanWeb, :controller

  alias Mealplan.Auth.{Otp, Sms}
  alias MealplanWeb.LoginPage
  alias MealplanWeb.Plugs.HouseholdSession

  require Logger

  @doc "GET /login — ask for a telephone number."
  def index(conn, params) do
    return_to = HouseholdSession.safe_return_to(params["return_to"])

    cond do
      # Already signed in: there is nothing to do here, and showing the form
      # would invite a second code nobody needs.
      HouseholdSession.identity_of(conn) != nil ->
        redirect(conn, to: return_to)

      # A login is in flight, so the code form is the screen they want back.
      pending(conn) != nil ->
        html(conn, LoginPage.code_form(return_to: return_to, phone: pending(conn).phone))

      true ->
        conn
        |> html(
          LoginPage.phone_form(
            return_to: return_to,
            configured: Mealplan.Config.owner_phone() != nil
          )
        )
    end
  end

  @doc """
  POST /login — send a code.

  Answers the same page whether or not the number was the household's. An
  answer that distinguished them would turn this form into an oracle for the
  household's telephone number.
  """
  def send_code(conn, params) do
    return_to = HouseholdSession.safe_return_to(params["return_to"])

    case Otp.start(params["phone"] || "") do
      {:ok, :ignored} ->
        # Nothing was sent. Show the code form anyway, and let it fail at the
        # code — which it will, because there is no login in flight to fail
        # against, and `verify/2` sends an unknown flow back to the start.
        conn
        |> put_pending(nil)
        |> html(LoginPage.code_form(return_to: return_to, phone: Otp.normalise(params["phone"])))

      {:ok, flow} ->
        conn
        |> put_pending(flow)
        |> html(LoginPage.code_form(return_to: return_to, phone: flow.phone))

      {:error, error} ->
        Logger.error("sign-in could not send a code: #{Exception.message(error)}")

        conn
        |> put_status(:service_unavailable)
        |> html(
          LoginPage.phone_form(
            return_to: return_to,
            configured: Mealplan.Config.owner_phone() != nil,
            error: sendable(error)
          )
        )
    end
  end

  @doc "POST /login/code — spend the code, and sign in."
  def verify(conn, params) do
    return_to = HouseholdSession.safe_return_to(params["return_to"])

    case {pending(conn), params["code"]} do
      {nil, _} ->
        # No login in flight. Either the session was dropped, or the number was
        # never the household's and `send_code/2` stored nothing.
        conn
        |> html(
          LoginPage.phone_form(
            return_to: return_to,
            configured: Mealplan.Config.owner_phone() != nil,
            error: "That code did not work. Ask for a new one."
          )
        )

      {flow, code} ->
        finish(conn, flow, code || "", return_to)
    end
  end

  @doc "POST /logout — drop the session."
  def logout(conn, _params) do
    conn
    |> HouseholdSession.sign_out()
    |> html(LoginPage.signed_out())
  end

  defp finish(conn, flow, code, return_to) do
    case Otp.finish(flow, code) do
      {:ok, user} ->
        Logger.info("the household signed in")

        conn
        # Rotates the session id, so a fixed one does not survive the sign-in.
        # It also drops the pending login, which is what makes a code
        # single-use here as well as in the core.
        |> HouseholdSession.sign_in(user)
        |> redirect(to: return_to)

      {:error, :wrong_code, left} when left > 0 ->
        again = if left == 1, do: "1 try left", else: "#{left} tries left"

        conn
        |> put_status(:unauthorized)
        |> html(
          LoginPage.code_form(
            return_to: return_to,
            phone: flow.phone,
            error: "That code is wrong — #{again}."
          )
        )

      {:error, :wrong_code, _} ->
        restart(conn, return_to, "Too many wrong codes. Ask for a new one.")

      {:error, :expired} ->
        restart(conn, return_to, "That code has expired. Ask for a new one.")

      {:error, :restart} ->
        restart(conn, return_to, "That sign-in is no longer valid. Ask for a new code.")

      {:error, error} ->
        Logger.error("sign-in could not check a code: #{Exception.message(error)}")

        restart(conn, return_to, "The sign-in service did not answer. Try again in a moment.")
    end
  end

  # Every dead end goes back to the telephone form with the flow cleared, so a
  # household never sits on a code form whose device the core has forgotten.
  defp restart(conn, return_to, message) do
    conn
    |> put_pending(nil)
    |> put_status(:unauthorized)
    |> html(
      LoginPage.phone_form(
        return_to: return_to,
        configured: Mealplan.Config.owner_phone() != nil,
        error: message
      )
    )
  end

  defp pending(conn), do: get_session(conn, :otp_pending)

  defp put_pending(conn, nil), do: delete_session(conn, :otp_pending)
  defp put_pending(conn, flow), do: put_session(conn, :otp_pending, flow)

  # What the household is allowed to read. A misconfigured provider is theirs
  # to know about — they are the one who cannot sign in — but a Twilio error
  # body can carry an account identifier, so only our own named refusals are
  # shown and everything else is a sentence with the journal behind it.
  defp sendable(%Sms.Error{status: nil, provider: nil} = error), do: Exception.message(error)

  defp sendable(_),
    do: "The code could not be sent. The journal for mealplan-elixir.service says why."
end
