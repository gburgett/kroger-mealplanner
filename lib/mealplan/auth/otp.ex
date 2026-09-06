defmodule Mealplan.Auth.Otp do
  @moduledoc """
  A household's sign-in, from a telephone number to a session. See ADR 0027 and
  ADR 0033.

  Two calls, and they are the whole of it:

      start/1   a number in, a message on that telephone, a pending login back
      finish/2  a code in, a `Mealplan.Accounts.User` back

  Between them sits `Mealplan.Auth.SuperTokens`, which owns everything that is
  quietly hard about a one-time code — the code itself, its lifetime, the
  binding to the device that asked, the failed-attempt count and the maximum.
  This module owns the two things the core cannot know: **who is allowed to ask**,
  and **what a successful code means for this product's own tables**.

  ## Who is allowed to ask

  Every household is invited by hand (ADR 0033). `start/1` admits a telephone
  when `Mealplan.Invitations` has a row for it, and refuses every other one
  **before** it calls the core. That ordering is the point: a stranger who
  guesses at the login page costs no message, creates no user in the core, and
  leaves nothing behind to clean up.

  The refusal does not say whether the number was invited. An answer that
  distinguishes "not invited" from "code sent" turns the login page into an
  oracle for which numbers are invited.

  ## What a successful code means

  `finish/2` redeems the invitation: the first code provisions the tenant, the
  owner user and the owner membership; a later one re-attaches and lands in the
  same tenant. `Mealplan.Invitations.redeem/2` does the work; this module hands
  back the `%User{}` the session names.
  """

  alias Mealplan.Accounts
  alias Mealplan.Auth.{Sms, SuperTokens}
  alias Mealplan.Invitations

  require Logger

  @typedoc """
  A login in flight. It goes in the browser's signed session, so it holds no
  code — only the two identifiers the core needs back, which are worth nothing
  without the code that arrived on the telephone.
  """
  @type pending :: %{
          pre_auth_session_id: String.t(),
          device_id: String.t(),
          phone: String.t(),
          started_at: integer()
        }

  @doc """
  Ask for a code for `phone`.

  Returns `{:ok, pending}` when a message went, and `{:error, exception}` when
  something is broken and the household should be told. A number that is not
  invited is `{:ok, :ignored}` — nothing happened, and the page says the same
  thing it says for a real send.
  """
  @spec start(String.t()) :: {:ok, pending()} | {:ok, :ignored} | {:error, Exception.t()}
  def start(phone) do
    normalised = normalise(phone)

    cond do
      not Invitations.invited?(normalised) ->
        # Deliberately quiet, and deliberately the same answer the caller gives
        # for a real send. Logged at info so the journal shows the attempt.
        Logger.info("sign-in refused: #{redact(normalised)} has no invitation")
        {:ok, :ignored}

      true ->
        send_code(normalised)
    end
  end

  @doc """
  Spend `code` against `pending`.

  Returns `{:ok, user}`, or one of the named failures
  `Mealplan.Auth.SuperTokens.consume_code/3` gives, which the caller turns into
  the sentence that fits.
  """
  @spec finish(pending(), String.t()) ::
          {:ok, Accounts.User.t() | struct()}
          | {:error, :wrong_code, non_neg_integer()}
          | {:error, :expired}
          | {:error, :restart}
          | {:error, Exception.t()}
  def finish(pending, code) do
    code = code |> to_string() |> String.replace(~r/[^0-9]/, "")

    case SuperTokens.consume_code(pending.pre_auth_session_id, pending.device_id, code) do
      {:ok, core_user} ->
        redeem(core_user, pending)

      other ->
        other
    end
  end

  defp redeem(core_user, pending) do
    phone = normalise(core_user.phone || pending.phone)

    case Invitations.get_by_phone(phone) do
      nil ->
        # The invitation was revoked between start/1 and finish/2. The code was
        # real, but there is nothing to sign into.
        {:error,
         %RuntimeError{
           message:
             "there is no invitation for this telephone any more. Ask whoever runs the " <>
               "meal planner to invite it again."
         }}

      invitation ->
        {:ok, _tenant} =
          Invitations.redeem(invitation, supertokens_user_id: core_user.id)

        {:ok, Invitations.owner_user(invitation)}
    end
  end

  @doc """
  Whether `phone` is invited. Compared after normalisation, so a number typed
  with spaces, brackets or hyphens still matches.
  """
  @spec invited?(String.t()) :: boolean()
  def invited?(phone), do: Invitations.invited?(normalise(phone))

  @doc """
  E.164, as far as a form field can be made into one: keep the digits, keep a
  leading `+`, drop everything a person types for legibility.

  This is not a validator. Twilio and Telnyx both reject a number that is not
  routable, and their refusal names the number, which is a better message than
  one written here.
  """
  @spec normalise(String.t() | nil) :: String.t()
  def normalise(nil), do: ""

  def normalise(phone) do
    trimmed = String.trim(phone)
    digits = String.replace(trimmed, ~r/[^0-9]/, "")

    if String.starts_with?(trimmed, "+"), do: "+" <> digits, else: digits
  end

  defp send_code(phone) do
    with {:ok, created} <- SuperTokens.create_code(phone),
         :ok <-
           Sms.send_code(phone, created.code,
             expires_in_minutes: max(div(created.expires_in_seconds, 60), 1)
           ) do
      {:ok,
       %{
         pre_auth_session_id: created.pre_auth_session_id,
         device_id: created.device_id,
         phone: phone,
         started_at: System.system_time(:second)
       }}
    end
  end

  # The journal is world-readable on this machine, and an attempt is logged
  # whether or not the number was invited.
  defp redact(phone) do
    case String.length(phone) do
      n when n > 4 -> String.duplicate("*", n - 4) <> String.slice(phone, -4, 4)
      _ -> "****"
    end
  end
end
