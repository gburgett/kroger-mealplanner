defmodule Mealplan.Features.OnboardingSteps do
  @moduledoc """
  A brand-new household's first commands, and the note that stops appearing
  once its own content shows onboarding is done. See ADR 0026.

  The generic steps this feature also uses — "a meal-plan folder mounted at",
  "the meal-plan folder is brand new", "I run", "I write the file", "the
  household prefers:", "the command succeeds", "the file ... exists in the
  meal-plan folder" — live in `corpus_steps.exs` and run unchanged; this file
  holds only what is specific to onboarding.
  """

  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias Mealplan.Features.BrowserSteps
  alias Mealplan.Mcp.Server
  alias Mealplan.Onboarding

  # --- the tool-call result -------------------------------------------------

  step "the tool result carries the onboarding note", context do
    assert_note(last_text(context))
    {:ok, context}
  end

  step "the tool result does not carry the onboarding note", context do
    refute_note(last_text(context))
    {:ok, context}
  end

  step "the onboarding note says to save a memory of this connector", context do
    text = last_text(context)
    assert String.contains?(text, "memory"), "the note never mentions memory:\n#{text}"
    assert String.contains?(text, "connector"), "the note never mentions the connector:\n#{text}"
    {:ok, context}
  end

  step "the onboarding note says to use it whenever the household asks about meals or groceries",
       context do
    text = last_text(context)

    assert String.contains?(text, "meals") and String.contains?(text, "groceries"),
           "the note never says when to use this connector:\n#{text}"

    {:ok, context}
  end

  step "the onboarding note says to ask for a photo of the fridge and the pantry", context do
    text = last_text(context)

    for word <- ["photo", "fridge", "pantry"] do
      assert String.contains?(text, word), "the note never says \"#{word}\":\n#{text}"
    end

    {:ok, context}
  end

  step "the onboarding note says to write what it sees into {string} and {string}",
       %{args: [first, second]} = context do
    text = last_text(context)

    for target <- [first, second] do
      assert String.contains?(text, target), "the note never names #{target}:\n#{text}"
    end

    {:ok, context}
  end

  step "the onboarding note says to ask for photos of the recipes in the household's recipe books",
       context do
    text = last_text(context)

    for word <- ["photo", "recipes", "books"] do
      assert String.contains?(text, word), "the note never says \"#{word}\":\n#{text}"
    end

    {:ok, context}
  end

  step "the onboarding note says to ask how many adults and how many children they cook for",
       context do
    text = last_text(context)

    for word <- ["adults", "children", "cooks"] do
      assert String.contains?(text, word), "the note never says \"#{word}\":\n#{text}"
    end

    {:ok, context}
  end

  step "the onboarding note says to write that family size into {string} as {string} and {string}",
       %{args: [target, first, second]} = context do
    text = last_text(context)

    for expected <- [target, first, second] do
      assert String.contains?(text, expected), "the note never names #{expected}:\n#{text}"
    end

    {:ok, context}
  end

  # --- the handshake instructions --------------------------------------------

  step "the meal planner's instructions carry the onboarding note", context do
    assert_note(Server.server_instructions())
    {:ok, context}
  end

  step "the meal planner's instructions do not carry the onboarding note", context do
    refute_note(Server.server_instructions())
    {:ok, context}
  end

  # --- the landing page -------------------------------------------------------

  step "a browser asks for the meal planner's landing page", context do
    {:ok, BrowserSteps.visit(context, "/")}
  end

  step "the page names this server's own MCP address", context do
    body = page_body(context)
    mcp_url = String.replace(Mealplan.Config.public_url(), ~r{/+$}, "") <> "/mcp"

    assert String.contains?(body, mcp_url),
           "the page never names #{mcp_url}:\n#{body}"

    {:ok, context}
  end

  step "the page tells a ChatGPT household to turn on Developer Mode", context do
    assert String.contains?(page_body(context), "Developer Mode"),
           "the page never mentions Developer Mode"

    {:ok, context}
  end

  step "the page says Developer Mode needs a Business, Enterprise or Edu workspace", context do
    body = page_body(context)

    for word <- ["Business", "Enterprise", "Edu"] do
      assert String.contains?(body, word), "the page never says \"#{word}\""
    end

    {:ok, context}
  end

  step "the page tells a Claude household to add a custom connector under Customize", context do
    body = page_body(context)

    assert String.contains?(body, "Customize") and String.contains?(body, "custom connector"),
           "the page never explains Claude's Customize path:\n#{body}"

    {:ok, context}
  end

  step "the page says Claude's mobile app cannot add a new connector by itself", context do
    body = page_body(context)

    assert String.contains?(body, "mobile") and
             (String.contains?(body, "cannot add") or String.contains?(body, "can't add")),
           "the page never explains the mobile restriction:\n#{body}"

    {:ok, context}
  end

  step "the page describes itself as an MCP server for assistants", context do
    assert String.contains?(page_body(context), "MCP server for AI assistants"),
           "the page never describes itself as an MCP server for assistants"

    {:ok, context}
  end

  step "the visible page content names the exact MCP address", context do
    body = page_body(context)
    mcp_url = String.replace(Mealplan.Config.public_url(), ~r{/+$}, "") <> "/mcp"

    assert String.contains?(body, mcp_url), "the page never names #{mcp_url}:\n#{body}"

    refute String.contains?(body, "<details"),
           "the MCP address is tucked inside a collapsed <details>, not in plain sight:\n#{body}"

    {:ok, context}
  end

  step "the page carries no block addressed only to an assistant", context do
    body = page_body(context)

    for phrase <- ["If you are an assistant", "Note for AI assistants"] do
      refute String.contains?(body, phrase),
             "the page still carries an assistant-only block: #{inspect(phrase)}"
    end

    {:ok, context}
  end

  step "the page never tells an assistant to connect or sign the household in on its own",
       context do
    body = page_body(context)

    for phrase <- ["authenticate the user when prompted", "Add it as a custom connector"] do
      refute String.contains?(body, phrase),
             "the page still tells an assistant to act unprompted: #{inspect(phrase)}"
    end

    {:ok, context}
  end

  # --- helpers ---------------------------------------------------------------

  defp last_text(context), do: (context[:last] || %{})[:text] || ""

  defp assert_note(text) do
    assert String.contains?(text, Onboarding.note()),
           "the onboarding note is missing from:\n#{text}"
  end

  defp refute_note(text) do
    refute String.contains?(text, Onboarding.note()),
           "the onboarding note is still there:\n#{text}"
  end

  defp page_body(context) do
    got = BrowserSteps.response(context)
    assert got.status == 200, "the landing page answered #{got.status}"
    got.body
  end
end
