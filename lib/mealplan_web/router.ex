defmodule MealplanWeb.Router do
  use MealplanWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :browser do
    plug :accepts, ["html"]
  end

  scope "/", MealplanWeb do
    pipe_through :browser

    get "/", StatusController, :index
  end

  scope "/api", MealplanWeb do
    pipe_through :api
  end
end
