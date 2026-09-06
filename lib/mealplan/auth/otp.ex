defmodule Mealplan.Auth.Otp do
  @moduledoc """
  The household's sign-in, from a telephone number to a session. See ADR 0027.

  Two calls, and they are the whole of it:

      start/1   a number in, a message on that telephone, a pending login back
      finish/2  a code in, a `Mealplan.Accounts.User` back

  Between them sits `Mealplan.Auth.SuperTokens`, which owns everything that is
  quietly hard about a one-time code — the code itself, its lifetime, the
  binding to the device that asked, the failed-attempt count and the maximum.
  This module owns the two things the core cannot know: **who is allowed to ask**,
  and **what a successful code means for this product's own user table**.

  ## Who is allowed to ask

  One household, one telephone (ADR 0008). `MEALPLAN_OWNER_PHONE` is that
  number, and `start/1` refuses every other one **before** it calls the core.
  That ordering is the point: a stranger who guesses at the login page costs no
  message, creates no user in the core, and leaves nothing behind to clean up.

  The refusal does not say whether the number was the household's. An answer
  that distinguishes "not the household" from "code sent" turns the login page
  into an oracle for the household's telephone number, and that number is worth
  something to somebody who wants to intercept the message.
  """

  alias Mealplan.Accounts
  alias Mealplan.Auth.{Sms, SuperTokens}
  alias Mealplan.Config

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
  the household's is `{:ok, :ignored}` — nothing happened, and the page says the
  same thing it says for a real send.
  """
  @spec start(String.t()) :: {:ok, pending()} | {:ok, :ignored} | {:error, Exception.t()}
  def start(phone) do
    normalised = normalise(phone)

    cond do
      is_nil(Config.owner_phone()) ->
        {:error,
         %RuntimeError{
           message:
             "no household telephone is configured, so nobody can sign in.\n\n" <>
               "Set MEALPLAN_OWNER_PHONE to the household's number in E.164 " <>
               "(for example +15095550142) and restart the server."
         }}

      not household?(normalised) ->
        # Deliberately quiet, and deliberately the same answer the caller gives
        # for a real send. Logged at info so the journal shows the attempt.
        Logger.info("sign-in refused: #{redact(normalised)} is not the household's telephone")
        {:ok, :ignored}

      true ->
        send_to_household(normalised)
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
        # The core says the code was right. This is where the answer becomes a
        # user of THIS product: the owner row seeded from MEALPLAN_OWNER gets
        # the telephone and the core's id attached to it, so the consent gate
        # can go on asking "does this user own this tenant".
        {:ok,
         Accounts.link_owner_login!(
           Config.tenant(),
           Config.owner(),
           phone: core_user.phone || pending.phone,
           supertokens_user_id: core_user.id
         )}

      other ->
        other
    end
  end

  @doc """
  Whether `phone` is the household's telephone. Compared after normalisation,
  so a number typed with spaces, brackets or hyphens still matches.
  """
  @spec household?(String.t()) :: boolean()
  def household?(phone) do
    case Config.owner_phone() do
      nil -> false
      owner -> secure_compare(normalise(owner), normalise(phone))
    end
  end

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

  defp send_to_household(phone) do
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

  # The household's telephone number is a secret worth a little care: a login
  # page that answers faster for a wrong first digit than for a wrong last one
  # leaks it a digit at a time. `Plug.Crypto.secure_compare/2` needs equal
  # lengths to be constant time, so pad both to the longer.
  defp secure_compare(one, other) do
    width = max(byte_size(one), byte_size(other))

    Plug.Crypto.secure_compare(
      String.pad_trailing(one, width, <<0>>),
      String.pad_trailing(other, width, <<0>>)
    )
  end

  # The journal is world-readable on this machine, and an attempt is logged
  # whether or not the number was the household's.
  defp redact(phone) do
    case String.length(phone) do
      n when n > 4 -> String.duplicate("*", n - 4) <> String.slice(phone, -4, 4)
      _ -> "****"
    end
  end
end
