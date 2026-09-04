defmodule Mealplan.Mock.Llm do
  @moduledoc """
  The exe.dev LLM gateway, stood in for. Ported from `features/support/llm.ts`.

  The third of the three mocks this project has, in the one shape the rule
  permits: a third-party HTTP API, a real listener on a real port. There are no
  more seams.

  A scenario scripts the turns the model will answer with, in order — an
  `end_turn` with some text, or a `tool_use` naming one of the job's three
  tools. The mock never generates anything: what comes back is exactly what was
  scripted, which is what makes "the job asked for exactly these tool calls, in
  this order, and stopped" something a scenario can assert. See ADR 0018.
  """

  alias Mealplan.Mock.Server

  @anthropic_version "2023-06-01"

  def anthropic_version, do: @anthropic_version

  @doc "Start the mock. The caller passes `.base` to `Mealplan.Recheck.run/1`."
  def start do
    Server.start(__MODULE__.Router, %{
      # Every request body this mock received, in order — decoded JSON.
      requests: [],
      turns: [],
      issued: 0
    })
  end

  defdelegate stop(mock), to: Server

  # --- scripting -------------------------------------------------------------

  @doc "The model ends its turn with nothing further to do."
  def script_end_turn(mock, text \\ "nothing here needs a recheck this week") do
    push(mock, %{kind: :end_turn, text: text})
  end

  @doc """
  The model calls one tool, and then ends its turn.

  A single scripted call is the common case: script the call, get the result,
  stop. Scenarios that need more than one turn call this, or `script_forever/3`,
  more than once.
  """
  def script_tool_use(mock, name, input) do
    push(mock, %{kind: :tool_use, name: name, input: input, repeat_forever: false})
  end

  @doc """
  The model keeps calling the same tool forever, never ending its turn.

  For the runaway scenario: the job's own turn ceiling has to be what stops
  this, not the mock running out of scripted turns.
  """
  def script_forever(mock, name, input) do
    push(mock, %{kind: :tool_use, name: name, input: input, repeat_forever: true})
  end

  @doc "Every request body, oldest first."
  def requests(mock), do: Enum.reverse(Server.state(mock).requests)

  @doc ~S|Every request's body, flattened to text, for a "mentions X" assertion.|
  def request_text(mock), do: mock |> requests() |> Enum.map_join("\n", &Jason.encode!/1)

  defp push(mock, turn) do
    Server.update(mock, &%{&1 | turns: &1.turns ++ [turn]})
    :ok
  end

  @doc false
  def next_turn(state) do
    case state.turns do
      [] -> {nil, state}
      [%{repeat_forever: true} = turn | _] -> {turn, state}
      [turn | rest] -> {turn, %{state | turns: rest}}
    end
  end
end
