defmodule Mealplan.Features.DocumentSteps do
  @moduledoc """
  The steps of `features/documents.feature` (ADR 0038, ADR 0039): the file
  verbs, their refusals, history and restore, and one household's documents
  against another's. `Mealplan.FeatureCorpus` holds the two rules — plant in a
  `Given`, call the real tool in a `When`.
  """

  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias Mealplan.Accounts.Tenant
  alias Mealplan.Documents, as: Shapes
  alias Mealplan.FeatureCorpus
  alias Mealplan.Mcp.Tools
  alias Mealplan.Repo
  alias Mealplan.Store.Documents

  # --- another household ------------------------------------------------------

  step "another household's meal plan holds the document {string}:",
       %{args: [path]} = context do
    other =
      Repo.insert!(
        Tenant.changeset(%Tenant{}, %{slug: "other-#{System.unique_integer([:positive])}"})
      )

    {:ok, _} = Documents.commit(other.id, [{path, context.docstring}], "theirs", context.now)
    {:ok, context}
  end

  # --- planting documents ---------------------------------------------------

  step "the document {string} holds:", %{args: [path]} = context do
    {:ok, plant(context, path, context.docstring)}
  end

  step "the recipe {string} serving {int} is stored as a document",
       %{args: [name, servings]} = context do
    {:ok,
     plant(
       context,
       Shapes.recipe_path(name),
       Shapes.recipe_document(name: name, servings: servings)
     )}
  end

  step "the recipe {string} serving {int} is stored as a document with the ingredients:",
       %{args: [name, servings]} = context do
    ingredients =
      Enum.map(context.datatable.maps, fn row ->
        %{quantity: row["quantity"], unit: row["unit"] || "", item: row["item"]}
      end)

    body = Shapes.recipe_document(name: name, servings: servings, ingredients: ingredients)
    {:ok, plant(context, Shapes.recipe_path(name), body)}
  end

  # What the /kroger store picker does: the server writes config/kroger.md.
  step "the household shops at Kroger store {string} for {word}",
       %{args: [name, modality]} = context do
    store = Mealplan.Mock.Kroger.store_named(name)

    {:ok, _} =
      Mealplan.Kroger.Config.write(
        context.corpus,
        context.now,
        %{
          location_id: store.location_id,
          name: store.name,
          address: store.address,
          modality: modality
        },
        Mealplan.Config.public_url()
      )

    {:ok, context}
  end

  # --- calling the tools ----------------------------------------------------

  step "I call {string}", %{args: [name]} = context do
    {:ok, call(context, name, %{})}
  end

  step "I call {string} with the command {string}", %{args: [name, command]} = context do
    {:ok, call(context, name, %{"command" => command, "message" => "bash #{command}"})}
  end

  step "I call {string} with the path {string}", %{args: [name, path]} = context do
    {:ok, call(context, name, %{"path" => path})}
  end

  step "I call {string} for {string}", %{args: [name, path]} = context do
    {:ok, call(context, name, %{"path" => path})}
  end

  step "I call {string} for {string} in {string}", %{args: [name, pattern, path]} = context do
    {:ok, call(context, name, %{"pattern" => pattern, "path" => path})}
  end

  step "I call {string} for {string} in {string} listing files only",
       %{args: [name, pattern, path]} = context do
    {:ok, call(context, name, %{"pattern" => pattern, "path" => path, "files_only" => true})}
  end

  step "I call {string} on {string}", %{args: [name, path]} = context do
    {:ok, call(context, name, %{"path" => path, "message" => "#{name} #{path}"})}
  end

  step "I write the document {string} with the message {string}:",
       %{args: [path, message]} = context do
    {:ok,
     call(context, "write_file", %{
       "path" => path,
       "content" => context.docstring <> "\n",
       "message" => message
     })}
  end

  step "I write the document {string} at version {int} with the message {string}:",
       %{args: [path, version, message]} = context do
    {:ok,
     call(context, "write_file", %{
       "path" => path,
       "content" => context.docstring <> "\n",
       "message" => message,
       "base_version" => version
     })}
  end

  step "I edit {string} replacing {string} with {string}", %{args: [path, old, new]} = context do
    {:ok,
     call(context, "edit_file", %{
       "path" => path,
       "old_string" => old,
       "new_string" => new,
       "message" => "edit #{path}"
     })}
  end

  step "I delete the document {string}", %{args: [path]} = context do
    {:ok, call(context, "delete_file", %{"path" => path, "message" => "delete #{path}"})}
  end

  # The change before the newest one that touched the path — what an agent
  # reads off `history` to undo its own last write.
  step "I restore {string} as it was before the last change", %{args: [path]} = context do
    [_newest, previous | _] = Documents.history(context.corpus.tenant_id, path, 2)

    {:ok,
     call(context, "restore_file", %{
       "path" => path,
       "change" => previous.id,
       "message" => "restore chicken tacos"
     })}
  end

  # --- what came back -------------------------------------------------------

  step "the tool call is refused", context do
    assert context.last.exit_code != 0, "the call succeeded:\n#{context.last.stdout}"
    {:ok, context}
  end

  step "the tool call succeeds", context do
    assert context.last.exit_code == 0, "the call was refused:\n#{context.last.stdout}"
    {:ok, context}
  end

  step "the tools offered include {string}, {string}, {string}, {string} and {string}",
       %{args: names} = context do
    offered = offered(context)
    for name <- names, do: assert(name in offered, "#{name} is not in #{inspect(offered)}")
    {:ok, context}
  end

  step "the tools offered do not include {string} or {string}", %{args: names} = context do
    offered = offered(context)
    for name <- names, do: refute(name in offered, "#{name} is offered")
    {:ok, context}
  end

  step "the document {string} exists", %{args: [path]} = context do
    assert Documents.get(context.corpus.tenant_id, path), "there is no document #{path}"
    {:ok, context}
  end

  step "the document {string} does not exist", %{args: [path]} = context do
    refute Documents.get(context.corpus.tenant_id, path), "#{path} was stored"
    {:ok, context}
  end

  step "the document {string} mentions {string}", %{args: [path, text]} = context do
    document = Documents.get(context.corpus.tenant_id, path)
    assert document, "there is no document #{path}"

    assert String.contains?(document.body, text),
           "#{inspect(text)} is not in #{path}:\n#{document.body}"

    {:ok, context}
  end

  # --- helpers ----------------------------------------------------------------

  defp plant(context, path, body), do: FeatureCorpus.plant(context, path, body)

  defp offered(_context), do: Enum.map(Tools.list(), & &1["name"])

  defp call(context, name, args), do: FeatureCorpus.call(context, name, args)
end
