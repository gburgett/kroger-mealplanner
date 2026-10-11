defmodule Mealplan.Store.DocumentsTest do
  @moduledoc """
  The document store's own rules (ADR 0038): paths, globs, the per-document and
  per-tenant limits, "no change when nothing changed", and an untrusted grep
  pattern. The behaviour an agent sees is specified in
  `features/documents.feature`; these are the edges a scenario would be a poor
  place for.
  """

  use Mealplan.DataCase

  alias Mealplan.Accounts.Tenant
  alias Mealplan.Mcp.DocumentTools
  alias Mealplan.Store.{Corpus, Documents, Paths}

  @now ~U[2026-08-23 12:00:00Z]

  setup do
    tenant =
      Repo.insert!(
        Tenant.changeset(%Tenant{}, %{
          slug: "store-test-#{System.unique_integer([:positive])}",
          store: "documents"
        })
      )

    %{tenant: tenant, corpus: %Corpus{tenant: tenant.slug, tenant_id: tenant.id}}
  end

  describe "paths" do
    test "a plain relative path is accepted as it is" do
      assert Paths.normalise("recipes/chicken-tacos.md") == {:ok, "recipes/chicken-tacos.md"}
    end

    test "anything that is not a plain relative path is refused, naming it" do
      for bad <- [
            "/etc/passwd",
            "../x.md",
            "recipes/../../x.md",
            ".git/config",
            "recipes/.x.md",
            "a b.md",
            "",
            "a//b.md"
          ] do
        assert {:error, message} = Paths.normalise(bad), "#{inspect(bad)} was accepted"
        assert is_binary(message)
      end
    end

    test "a glob matches inside one folder with * and across folders with **" do
      august = Paths.glob_regex("meals/2026-08-*.md")
      assert Regex.match?(august, "meals/2026-08-25.md")
      refute Regex.match?(august, "meals/2026-09-01.md")
      refute Regex.match?(august, "meals/2026-08/x.md")

      everything = Paths.glob_regex("**/*.md")
      assert Regex.match?(everything, "README.md")
      assert Regex.match?(everything, "recipes/chicken-tacos.md")

      assert Regex.match?(Paths.glob_regex("recipes/**/x.md"), "recipes/x.md")
      refute Regex.match?(Paths.glob_regex("recipes/x?.md"), "recipes/x.md")
    end
  end

  describe "commit" do
    test "several writes are one change, and history names each path", %{tenant: t} do
      {:ok, change} = Documents.commit(t.id, [{"a.md", "a"}, {"b.md", "b"}], "two at once", @now)
      assert [%{id: id, message: "two at once", paths: paths}] = Documents.history(t.id)
      assert id == change.id
      assert paths == [{"a.md", false}, {"b.md", false}]
    end

    test "a write that changes nothing records nothing", %{tenant: t} do
      {:ok, _} = Documents.commit(t.id, [{"a.md", "a"}], "first", @now)
      assert {:ok, :unchanged} = Documents.commit(t.id, [{"a.md", "a"}], "again", @now)

      assert {:ok, :unchanged} =
               Documents.commit(t.id, [{"gone.md", :delete}], "delete nothing", @now)

      assert length(Documents.history(t.id)) == 1
    end

    test "every version stays readable, and a delete is a version too", %{tenant: t} do
      {:ok, one} = Documents.commit(t.id, [{"a.md", "one"}], "one", @now)
      {:ok, two} = Documents.commit(t.id, [{"a.md", "two"}], "two", @now)
      {:ok, gone} = Documents.commit(t.id, [{"a.md", :delete}], "gone", @now)

      assert Documents.body_at(t.id, "a.md", one.id) == {:ok, "one"}
      assert Documents.body_at(t.id, "a.md", two.id) == {:ok, "two"}
      assert Documents.body_at(t.id, "a.md", gone.id) == {:ok, nil}
      assert Documents.get(t.id, "a.md") == nil
    end

    test "one document is at most the per-document limit", %{tenant: t} do
      big = String.duplicate("x", Documents.max_document_bytes() + 1)
      assert {:error, message} = Documents.commit(t.id, [{"big.md", big}], "too big", @now)
      assert message =~ "big.md"
      assert Documents.count(t.id) == 0
    end

    test "one household holds at most the per-tenant number of documents", %{tenant: t} do
      writes = for n <- 1..Documents.max_documents(), do: {"shopping-lists/#{n}.md", "#{n}"}
      {:ok, _} = Documents.commit(t.id, writes, "fill it", @now)

      assert {:error, message} = Documents.commit(t.id, [{"one-more.md", "x"}], "over", @now)
      assert message =~ "at most #{Documents.max_documents()}"

      # Replacing a document that is there is not a new one.
      assert {:ok, _} = Documents.commit(t.id, [{"shopping-lists/1.md", "changed"}], "edit", @now)
    end

    test "one tenant's rows are invisible to another", %{tenant: t} do
      other =
        Repo.insert!(Tenant.changeset(%Tenant{}, %{slug: "store-test-other", store: "documents"}))

      {:ok, _} = Documents.commit(other.id, [{"recipes/theirs.md", "theirs"}], "theirs", @now)

      assert Documents.get(t.id, "recipes/theirs.md") == nil
      assert Documents.list(t.id) == []
      assert Documents.history(t.id) == []
    end
  end

  describe "corpus writes" do
    test "a path is a document or a folder, never both", %{corpus: corpus} do
      {:ok, _} = Corpus.write(corpus, "notes", "a document called notes", "notes", @now)

      assert {:error, message} = Corpus.write(corpus, "notes/today.txt", "x", "under it", @now)
      assert message =~ ~s("notes" is a document)

      assert {:error, message} = Corpus.write(corpus, "recipes", "x", "over a folder", @now)
      assert message =~ "is a folder"
    end
  end

  describe "grep" do
    test "a catastrophic pattern is stopped, not run to the end", %{corpus: corpus} do
      {:ok, _} =
        Documents.commit(
          corpus.tenant_id,
          [{"a.md", String.duplicate("a", 40) <> "!"}],
          "a",
          @now
        )

      {micros, result} =
        :timer.tc(fn -> DocumentTools.call("grep", %{"pattern" => "(a+)+$"}, corpus, @now) end)

      assert micros < 3_000_000
      assert [%{"text" => _}] = result["content"]
    end

    test "a pattern that is not a regular expression is named", %{corpus: corpus} do
      result = DocumentTools.call("grep", %{"pattern" => "(unclosed"}, corpus, @now)
      assert result["isError"]
      assert hd(result["content"])["text"] =~ "not a regular expression"
    end
  end
end
