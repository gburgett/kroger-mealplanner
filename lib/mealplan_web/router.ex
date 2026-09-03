defmodule MealplanWeb.Router do
  use MealplanWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", MealplanWeb do
    pipe_through :api
  end
end
