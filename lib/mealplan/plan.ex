defmodule Mealplan.Plan do
  @moduledoc """
  The seam between the `start_meal_plan` / `save_meal_plan` tools and the
  `mealplan plan` subcommands that do the work (ADR 0040, ADR 0041).

  THIS MODULE DOES NOT PARSE A PLAN. ADR 0040 put every read and write of a
  plan document in the CLI, which is where ADR 0007 says a corpus parser
  belongs. What happens here is: lay the household's documents out for the
  parser (`Mealplan.Store.Cli`), run one subcommand with an argument vector
  built from validated arguments, decode the JSON it printed, and store the
  document it wrote as one change.

  The posted document travels on standard input, never in the argument
  vector. With nothing on standard input `plan save` works on what is saved,
  which is what a regenerate needs.

  Exit `0` is done, `1` is "saved, and the plan has problems" — the JSON is
  printed either way — and `2` is an argument the CLI refused, which is
  stderr and no JSON at all.
  """

  alias Mealplan.Store.{Corpus, Documents, Paths}

  @doc """
  Begin a plan, store it, and record it as one change.
  """
  @spec start(Corpus.t(), String.t(), String.t(), String.t() | nil, String.t(), DateTime.t()) ::
          {:ok, map()} | {:error, String.t()}
  def start(%Corpus{} = corpus, from, to, name, message, now) do
    args =
      ["plan", "start", "--from", from, "--to", to] ++
        if(name, do: ["--name", name], else: []) ++ ["--json"]

    with {:ok, result} <- Corpus.run_cli(corpus, args),
         {:ok, decoded} <- decode(result),
         # `plan start` prints exactly the bytes it wrote, so the document in
         # the JSON is the document to store.
         {:ok, path} <- Paths.normalise(decoded["path"]),
         {:ok, _} <- Corpus.commit(corpus, [{path, decoded["document"]}], message, now) do
      {:ok, decoded}
    end
  end

  @doc """
  Save a plan: check it, do the arithmetic, and store what the CLI wrote.

  `html` may be `nil`, and that is the point of the regenerate call — with no
  document posted the CLI works on what is already saved, so putting one
  ingredient back costs one small call rather than a repost of the whole
  document. An unchanged document records no change.
  """
  @spec save(
          Corpus.t(),
          String.t(),
          String.t() | nil,
          [String.t()],
          String.t(),
          String.t(),
          DateTime.t()
        ) :: {:ok, map()} | {:error, String.t()}
  def save(%Corpus{} = corpus, path, html, regenerate, returning, message, now) do
    with {:ok, path} <- Paths.normalise(path),
         :ok <- saved_or_posted(corpus, path, html) do
      args =
        ["plan", "save", "--path", path, "--return", returning] ++
          Enum.flat_map(regenerate, &["--regenerate", &1]) ++ ["--json"]

      with {:ok, result} <- Corpus.run_cli(corpus, args, input: html, collect: [path]),
           {:ok, decoded} <- decode(result),
           {:ok, body} <- Map.fetch(result.files, path) |> written(path),
           {:ok, _} <- Corpus.commit(corpus, [{path, body}], message, now) do
        {:ok, decoded}
      end
    end
  end

  # A save with no document works on the stored one, so there has to be one.
  # The CLI says the same, but a missing plan is the agent's most likely slip,
  # and this refusal can name the plans that do exist.
  defp saved_or_posted(_corpus, _path, html) when is_binary(html), do: :ok

  defp saved_or_posted(corpus, path, nil) do
    if Documents.get(corpus.tenant_id, path) do
      :ok
    else
      with {:error, message} <- Corpus.fetch(corpus, path) do
        {:error,
         message <>
           " Pass the document as \"html\", or start one with start_meal_plan."}
      end
    end
  end

  defp written({:ok, body}, _path), do: {:ok, body}

  defp written(:error, path),
    do: {:error, "mealplan plan save printed a result but did not write #{path}."}

  defp decode(%{exit_code: code} = result) when code in [0, 1] do
    case Jason.decode(result.stdout) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, refusal(result)}
    end
  end

  defp decode(result), do: {:error, refusal(result)}

  defp refusal(result) do
    [result.stderr, result.stdout]
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> case do
      "" -> "mealplan plan exited #{result.exit_code} and said nothing."
      text -> text
    end
  end

  @doc """
  What the tool hands back: the document or the changed sections, then the
  problems and warnings, in that order.

  The document comes first because the assistant's next act is to show it, and
  the problems come after because they are about what it is showing.
  """
  @spec render(map()) :: String.t()
  def render(decoded) do
    [
      document_text(decoded),
      issues("problem", Map.get(decoded, "problems", [])),
      issues("warning", Map.get(decoded, "warnings", []))
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp document_text(decoded) do
    case {Map.get(decoded, "document"), Map.get(decoded, "changed")} do
      {document, _} when is_binary(document) ->
        document

      {_, changed} when is_list(changed) and changed != [] ->
        [
          "These sections changed. Replace them in the document you are showing, and leave the " <>
            "rest of it alone.",
          Enum.map_join(changed, "\n\n", fn section ->
            "<!-- #{section["section"]} -->\n#{section["html"]}"
          end)
        ]
        |> Enum.join("\n\n")

      {_, _} ->
        "Saved #{Map.get(decoded, "path")}. Nothing changed."
    end
  end

  defp issues(_kind, []), do: ""

  defp issues(kind, issues) do
    heading =
      case {kind, length(issues)} do
        {"problem", 1} -> "One problem:"
        {"problem", count} -> "#{count} problems:"
        {"warning", 1} -> "One warning:"
        {"warning", count} -> "#{count} warnings:"
      end

    lines =
      Enum.map_join(issues, "\n", fn issue ->
        where =
          case issue["line"] do
            nil -> issue["file"]
            line -> "#{issue["file"]}:#{line}"
          end

        "  #{where}: #{issue["message"]}"
      end)

    "#{heading}\n#{lines}"
  end
end
