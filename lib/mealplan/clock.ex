defmodule Mealplan.Clock do
  @moduledoc """
  The one place time enters the running server.

  Production reads the wall clock. A scenario freezes it: the Cucumber suite
  runs the release as its own OS process and cannot inject a function, so it
  pins the instant through `MEALPLAN_CLOCK` (an ISO 8601 timestamp), read in
  `config/runtime.exs` into `:mealplan, :clock`. This mirrors the `now: Clock`
  option the TypeScript `startServer` took.
  """

  @spec now() :: DateTime.t()
  def now do
    case Application.get_env(:mealplan, :clock) do
      nil ->
        DateTime.utc_now()

      iso when is_binary(iso) ->
        case DateTime.from_iso8601(iso) do
          {:ok, dt, _offset} -> dt
          _ -> DateTime.utc_now()
        end

      %DateTime{} = dt ->
        dt

      fun when is_function(fun, 0) ->
        fun.()
    end
  end
end
