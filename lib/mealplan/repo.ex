defmodule Mealplan.Repo do
  use Ecto.Repo,
    otp_app: :mealplan,
    adapter: Ecto.Adapters.Postgres
end
