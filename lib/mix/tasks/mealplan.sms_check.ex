defmodule Mix.Tasks.Mealplan.SmsCheck do
  @shortdoc "Prove the SMS provider is configured by sending a test message (ADR 0028)"

  @moduledoc """
  Send one plainly-labelled test message through the configured SMS provider.

      mix mealplan.sms_check +19722759023

  The SuperTokens core does not send messages — `Mealplan.Auth.Sms` does, as an
  ordinary third-party HTTP call from the server process (ADR 0028). A new
  `TELNYX_API_KEY` or Twilio credential is otherwise not proven until a
  household cannot sign in. This task makes that call now instead, against the
  real provider, and prints what it said.

  The secrets live in `.env.elixir` (0600, gitignored), which systemd loads for
  the service but a shell does not. Load it first:

      set -a; . ./.env.elixir; set +a
      mix mealplan.sms_check +19722759023

  It sends a real message and, on some providers, costs a fraction of a cent.
  The body names the meal planner and says it is a test, so the recipient is
  not left reading it as a scam.
  """

  use Mix.Task

  alias Mealplan.Auth.Sms
  alias Mealplan.Config

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {_opts, rest, _invalid} = OptionParser.parse(argv, strict: [])

    phone =
      case rest do
        [phone] ->
          phone

        _ ->
          Mix.raise("give exactly one telephone number, in E.164, for example +19722759023")
      end

    # Only the HTTP client is needed — not the endpoint, the repo or the
    # sandbox. Starting the whole app would bind a port and open a database
    # for a single outbound call.
    {:ok, _} = Application.ensure_all_started(:req)

    Mix.shell().info("provider:  #{Config.sms_provider()}")
    Mix.shell().info("from:      #{Config.sms_from() || "(MEALPLAN_SMS_FROM not set)"}")
    Mix.shell().info("to:        #{phone}")

    case Sms.why_not() do
      nil ->
        :ok

      why ->
        Mix.raise("""
        the SMS provider is not fully configured: #{why}

        Did you load the secrets file? Run this first, from the repo root:

            set -a; . ./.env.elixir; set +a
        """)
    end

    Mix.shell().info("\nsending #{inspect(Sms.test_message())} ...")

    case Sms.send_test(phone) do
      :ok ->
        Mix.shell().info("\nsent. The provider accepted the message. Check the handset.")

      {:error, error} ->
        Mix.raise("the provider refused the message: #{Exception.message(error)}")
    end
  end
end
