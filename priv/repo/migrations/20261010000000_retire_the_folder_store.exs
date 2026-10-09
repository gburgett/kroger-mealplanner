defmodule Mealplan.Repo.Migrations.RetireTheFolderStore do
  @moduledoc """
  ADR 0039: every household's meal plan is documents in this database, so a
  tenant no longer names a folder on disk or which store it uses. The rows that
  were folder households are moved by hand on the server; this migration only
  drops the two columns that pointed at the old store.
  """

  use Ecto.Migration

  def change do
    alter table(:tenants) do
      remove :store, :string, null: false, default: "folder"
      remove :corpus_path, :string
    end
  end
end
