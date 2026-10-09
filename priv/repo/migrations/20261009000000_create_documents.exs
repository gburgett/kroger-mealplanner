defmodule Mealplan.Repo.Migrations.CreateDocuments do
  @moduledoc """
  ADR 0038: a tenant's meal plan as documents in this database.

  The first migration says the database "never holds the corpus". For a tenant
  whose `store` is `"documents"` that is no longer true, and this is where it
  stops being true.

  - `documents` is the current body of each document, keyed by tenant and
    path. The path is the primary key, exactly as the filename was.
  - `document_changes` is one row per change — the unit of history, as a
    commit was. A change can touch more than one document.
  - `document_versions` is the body of each document after each change. A null
    body is a deletion.

  There are no derived tables (no ingredients, no meal links). They would be an
  index that can drift out of step with the body, and the body is the truth.
  """

  use Ecto.Migration

  def change do
    alter table(:tenants) do
      # "folder" (ADR 0008's sandboxed folder) or "documents" (ADR 0038).
      add :store, :string, null: false, default: "folder"
    end

    create table(:documents, primary_key: false) do
      add :tenant_id, references(:tenants, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :path, :string, null: false, primary_key: true
      add :body, :text, null: false
      # Per document: 1 on create, +1 on every change that touches it. What a
      # `write_file` with `base_version` is compared against.
      add :version, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create table(:document_changes) do
      add :tenant_id, references(:tenants, on_delete: :delete_all), null: false
      add :message, :text, null: false
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:document_changes, [:tenant_id])

    create table(:document_versions) do
      add :change_id, references(:document_changes, on_delete: :delete_all), null: false
      add :tenant_id, references(:tenants, on_delete: :delete_all), null: false
      add :path, :string, null: false
      add :version, :integer, null: false
      # Null when this change deleted the document.
      add :body, :text
    end

    create index(:document_versions, [:tenant_id, :path])
    create index(:document_versions, [:change_id])
  end
end
