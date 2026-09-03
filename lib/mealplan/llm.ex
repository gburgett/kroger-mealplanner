defmodule Mealplan.Llm do
  @moduledoc """
  The exe.dev LLM gateway, from the server process, outside the sandbox. Ported
  from `src/gateway/llm.ts`. See ADR 0018.

  IT NEEDS NO API KEY — the exe.dev integration authenticates by the VM's own
  network identity. `MEALPLAN_LLM_BASE` (`Mealplan.Config.llm_base/0`) is the
  mock seam, passed in rather than read at call time so scenarios sharing one
  process stay isolated.
  """

  @anthropic_version "2023-06-01"

  @doc """
  One call, Anthropic Messages API shape. No retry, no streaming: a turn in the
  recheck job's loop is a handful of small documents, not a long generation.

  `request` is a plain map with string keys (`"model"`, `"max_tokens"`,
  `"system"`, `"messages"`, `"tools"`). Returns `{:ok, response_map}` or
  `{:error, message}`.
  """
  def call(base, request) do
    url = String.trim_trailing(base, "/") <> "/v1/messages"

    case Req.post(url,
           json: request,
           headers: [{"anthropic-version", @anthropic_version}],
           retry: false,
           decode_body: :json
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "the LLM gateway answered #{status}: #{describe(body)}"}

      {:error, exception} ->
        {:error, "the LLM gateway could not be reached at #{base}: #{Exception.message(exception)}"}
    end
  end

  defp describe(body) when is_binary(body), do: body
  defp describe(body), do: Jason.encode!(body)
end
