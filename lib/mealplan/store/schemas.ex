defmodule Mealplan.Store.Document do
  @moduledoc """
  One document in a tenant's meal plan (ADR 0038): its path, its whole
  markdown body, and its version. `(tenant_id, path)` is the primary key, the
  way the filename was in the folder.
  """
  use Ecto.Schema

  @primary_key false
  schema "documents" do
    field :tenant_id, :integer, primary_key: true
    field :path, :string, primary_key: true
    field :body, :string
    field :version, :integer
    timestamps(type: :utc_datetime)
  end
end

defmodule Mealplan.Store.Change do
  @moduledoc """
  One change to a tenant's documents — the unit of history, as a commit was in
  the folder. Its message is the one the agent (or the tool) gave.
  """
  use Ecto.Schema

  schema "document_changes" do
    field :tenant_id, :integer
    field :message, :string
    field :inserted_at, :utc_datetime
    has_many :versions, Mealplan.Store.Version
  end
end

defmodule Mealplan.Store.Version do
  @moduledoc """
  A document's body after one change. A nil body means the change deleted it.
  """
  use Ecto.Schema

  schema "document_versions" do
    belongs_to :change, Mealplan.Store.Change
    field :tenant_id, :integer
    field :path, :string
    field :version, :integer
    field :body, :string
  end
end
