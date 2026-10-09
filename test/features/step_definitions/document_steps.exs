defmodule Mealplan.Features.DocumentSteps do
  @moduledoc """
  The steps of `features/documents.feature` (ADR 0038).

  The same two rules as every other step file:

    * **A `Given` step may write directly** — here that is a row through
      `Mealplan.Store.Documents.commit/4`, the way a folder `Given` writes a
      file. It is setup, and it is not checked by the parser.
    * **A `When` step goes through the real interface**:
      `Mealplan.Mcp.Tools.call/4`, the function the MCP server calls.

  A tool result is put in `context.last` in the shape the folder steps use, so
  "the output is", "the output mentions" and the rest are shared rather than
  written twice.
  """

  use Cucumber.StepDefinition

  import ExUnit.Assertions
  import Ecto.Query

  alias Mealplan.Accounts.Tenant
  alias Mealplan.Documents, as: Shapes
  alias Mealplan.Mcp.Tools
  alias Mealplan.Repo
  alias Mealplan.Store.{Change, Corpus, Document, Documents}

  # --- the household's store ------------------------------------------------

  # The scenario's tenant was provisioned over a folder by the before_scenario
  # hook. It becomes a document tenant here, with no folder to import, so it
  # starts from the scaffold alone.
  step "the household's meal plan is stored as documents", context do
    Mealplan.Features.CorpusHooks.close_session(context.tenant)

    tenant(context)
    |> Ecto.Changeset.change(store: "documents", corpus_path: nil)
    |> Repo.update!()

    {:ok, Map.put(context, :corpus, open(context))}
  end

  step "the household's folder holds the recipe {string} serving {int}",
       %{args: [name, servings]} = context do
    path = Path.join(context.folder, Shapes.recipe_path(name))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Shapes.recipe_document(name: name, servings: servings))
    {:ok, context}
  end

  # A tenant that moves keeps its folder: the store finds it empty, so the
  # first open imports the folder. The scaffold the Background made is wiped
  # first, so the move is from a folder to an empty store, as it is for real.
  step "the household's meal plan moves from its folder to documents", context do
    tenant = tenant(context)
    Repo.delete_all(from d in Document, where: d.tenant_id == ^tenant.id)
    Repo.delete_all(from c in Change, where: c.tenant_id == ^tenant.id)

    tenant
    |> Ecto.Changeset.change(store: "documents", corpus_path: context.folder)
    |> Repo.update!()

    {:ok, Map.put(context, :corpus, open(context))}
  end

  step "another household's meal plan holds the document {string}:",
       %{args: [path]} = context do
    other =
      Repo.insert!(
        Tenant.changeset(%Tenant{}, %{
          slug: "other-#{System.unique_integer([:positive])}",
          store: "documents"
        })
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

  step "dinner on {string} is stored as a document with the recipe {string}",
       %{args: [date, name]} = context do
    {:ok,
     plant(context, Shapes.day_path(date), Shapes.dinner_document(date: date, recipes: [name]))}
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

  step "I call {string} from {string} to {string} out to {string}",
       %{args: [name, from, to, out]} = context do
    {:ok, call(context, name, %{"from" => from, "to" => to, "out" => out})}
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

  step "the household's folder on disk has no {string}", %{args: [path]} = context do
    refute File.exists?(Path.join(context.folder, path)), "#{path} was written to disk"
    {:ok, context}
  end

  # --- helpers ----------------------------------------------------------------

  defp tenant(context), do: Repo.get_by!(Tenant, slug: context.tenant)

  defp open(context),
    do: Corpus.open(context.tenant, now: context.now, base_url: Mealplan.Config.public_url())

  defp plant(context, path, body) do
    {:ok, _} =
      Documents.commit(context.corpus.tenant_id, [{path, body}], "given #{path}", context.now)

    context
  end

  defp offered(context), do: Enum.map(Tools.list(context.tenant), & &1["name"])

  defp call(context, name, args) do
    {:ok, response} = Tools.call(name, args, context.tenant, context.now)

    text =
      response["content"]
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.reject(&(&1["text"] == Mealplan.Onboarding.note()))
      |> Enum.map_join("\n", & &1["text"])

    Map.put(context, :last, %{
      stdout: text,
      stderr: "",
      exit_code: if(response["isError"], do: 1, else: 0),
      timed_out: false,
      truncated: false,
      text: text
    })
  end
end
