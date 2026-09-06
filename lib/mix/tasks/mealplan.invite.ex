defmodule Mix.Tasks.Mealplan.Invite do
  @shortdoc "Invite a household by telephone number, or revoke one (ADR 0033)"

  @moduledoc """
  Admit a household through the sign-in flow, or take one back out.

      mix mealplan.invite +15095550142 [--label "The Smiths"]
      mix mealplan.invite --revoke +15095550142

  There is no HTTP path and no screen for this. An invite grants a shell over a
  corpus for years, and the authority to grant that is shell access to the VM —
  the same bar as `mix mealplan.recheck` and the ADR 0028 recovery task. A
  release runs it with:

      bin/mealplan eval 'Mealplan.Invitations.create("+15095550142", label: "...")'

  It also says, every time, when the sandbox backend cannot isolate one
  household from another: bubblewrap shares one kernel, and real isolation is
  `MEALPLAN_SANDBOX=microsandbox` (ADR 0027).
  """

  use Mix.Task

  @requirements ["app.config"]

  @switches [label: :string, revoke: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, rest, _invalid} = OptionParser.parse(argv, strict: @switches)

    {:ok, _} = Application.ensure_all_started(:mealplan)

    phone =
      case rest do
        [phone] -> phone
        _ -> Mix.raise("give exactly one telephone number, in E.164, for example +15095550142")
      end

    if opts[:revoke], do: revoke(phone), else: invite(phone, opts[:label])

    warn_about_sandbox()
  end

  defp invite(phone, label) do
    case Mealplan.Invitations.create(phone, label: label) do
      {:ok, invitation} ->
        Mix.shell().info("invited #{invitation.phone}#{if label, do: " (#{label})", else: ""}")

        Mix.shell().info(
          "They can now sign in at the login page. The first code they enter provisions " <>
            "their own tenant and a fresh scaffolded folder."
        )

      {:error, :already_invited} ->
        Mix.shell().info("#{phone} is already invited. Nothing to do.")

      {:error, changeset} ->
        Mix.raise("could not invite #{phone}: #{errors(changeset)}")
    end
  end

  defp revoke(phone) do
    case Mealplan.Invitations.revoke(phone) do
      {:ok, :unredeemed} ->
        Mix.shell().info("removed the unredeemed invitation for #{phone}.")

      {:ok, :redeemed} ->
        Mix.shell().info(
          "removed the owner membership for #{phone}. Their clients are locked out on the " <>
            "next request. The tenant row and its folder stay on disk for you to remove."
        )

      {:error, :not_found} ->
        Mix.shell().info("no invitation for #{phone}. Nothing to do.")
    end
  end

  # Named every run, not only when it is a problem: a person inviting a second
  # household on the default backend has weakened the boundary and should see it
  # said. See docs/multi-tenant-isolation-trade-study.md §10.
  defp warn_about_sandbox do
    unless Mealplan.Sandbox.mode() == :microsandbox do
      Mix.shell().info([
        :yellow,
        "\nwarning: the sandbox backend is #{Mealplan.Sandbox.mode()}, which shares one " <>
          "kernel between households. Real isolation between tenants is " <>
          "MEALPLAN_SANDBOX=microsandbox (ADR 0027) — set it in " <>
          "deploy/mealplan-elixir.service before a second household is reachable.",
        :reset
      ])
    end
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end
end
