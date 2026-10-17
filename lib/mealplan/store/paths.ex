defmodule Mealplan.Store.Paths do
  @moduledoc """
  What a document path may be (ADR 0038).

  There is no file system under a document path, so there is no symlink to
  plant and no mount to escape. What is left to check is that the path names a
  document the way a folder would: relative, plain segments, no `..`, nothing
  hidden. The refusals name the path and say what a good one looks like,
  because the agent recovers from that and from nothing vaguer.
  """

  @max_path_bytes 200
  @max_depth 4
  @segment ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  @doc """
  The path in canonical form — `./` and a leading `/` are NOT forgiven, because
  the folder store refused them too — or `{:error, message}` naming what is
  wrong with it.
  """
  @spec normalise(term()) :: {:ok, String.t()} | {:error, String.t()}
  def normalise(path) when is_binary(path) do
    trimmed = path |> String.trim() |> String.trim_trailing("/")
    segments = String.split(trimmed, "/")

    cond do
      trimmed == "" ->
        {:error,
         ~s(the path is empty. Name a document relative to the meal-plan root, for example "recipes/chicken-tacos.md".)}

      String.starts_with?(trimmed, "/") ->
        {:error, outside(path, "it starts with \"/\"")}

      Enum.any?(segments, &(&1 == "..")) ->
        {:error, outside(path, "it climbs out with \"..\"")}

      byte_size(trimmed) > @max_path_bytes ->
        {:error, ~s("#{path}" is longer than #{@max_path_bytes} bytes. Use a shorter name.)}

      length(segments) > @max_depth ->
        {:error,
         ~s("#{path}" is #{length(segments)} folders deep. The meal plan is at most #{@max_depth} deep — ) <>
           ~s(for example "recipes/chicken-tacos.md".)}

      bad = Enum.find(segments, &(not Regex.match?(@segment, &1))) ->
        {:error,
         ~s("#{path}" has a part, "#{bad}", that is not a plain name. Each part of a path is letters, ) <>
           ~s(digits, ".", "-" and "_", and does not start with "." — for example "recipes/chicken-tacos.md".)}

      true ->
        {:ok, trimmed}
    end
  end

  def normalise(_), do: {:error, "the path must be a string, relative to the meal-plan root."}

  @doc """
  A directory argument: like `normalise/1`, but "" and "." mean the root.
  """
  @spec directory(term()) :: {:ok, String.t()} | {:error, String.t()}
  def directory(nil), do: {:ok, ""}

  def directory(path) when is_binary(path) do
    case String.trim(path) do
      "" -> {:ok, ""}
      "." -> {:ok, ""}
      "./" -> {:ok, ""}
      _ -> normalise(path)
    end
  end

  def directory(other), do: normalise(other)

  @doc """
  A glob over document paths, as a regex. `*` is any run of characters inside
  one folder, `**` is any run across folders, `?` is one character. Everything
  else is literal.
  """
  @spec glob_regex(String.t()) :: Regex.t()
  def glob_regex(glob) do
    body =
      glob
      |> String.trim()
      |> String.trim_leading("./")
      |> tokenize([])
      |> Enum.map_join(fn
        :globstar_dir -> "(?:.*/)?"
        :globstar -> ".*"
        :star -> "[^/]*"
        :one -> "[^/]"
        {:lit, c} -> Regex.escape(c)
      end)

    Regex.compile!("\\A" <> body <> "\\z")
  end

  @doc "True when `pattern` has a glob character in it."
  @spec glob?(String.t()) :: boolean()
  def glob?(pattern), do: String.contains?(pattern, ["*", "?"])

  defp tokenize("", acc), do: Enum.reverse(acc)
  defp tokenize("**/" <> rest, acc), do: tokenize(rest, [:globstar_dir | acc])
  defp tokenize("**" <> rest, acc), do: tokenize(rest, [:globstar | acc])
  defp tokenize("*" <> rest, acc), do: tokenize(rest, [:star | acc])
  defp tokenize("?" <> rest, acc), do: tokenize(rest, [:one | acc])

  defp tokenize(<<c::utf8, rest::binary>>, acc), do: tokenize(rest, [{:lit, <<c::utf8>>} | acc])

  defp outside(path, why) do
    ~s("#{path}" is outside the meal plan: #{why}. Paths are relative to the meal-plan root, ) <>
      ~s(for example "recipes/chicken-tacos.md".)
  end
end
