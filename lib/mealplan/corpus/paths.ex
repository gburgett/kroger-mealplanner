defmodule Mealplan.Corpus.Paths do
  @moduledoc """
  The shell scripts every corpus read and write runs inside the sandbox, and
  the "outside the folder" refusal. Ported from `src/corpus/sandbox.ts` and
  `src/corpus/files.ts` (ADR 0021).

  THE PATH AND THE CONTENT ARE NEVER INTERPOLATED INTO THE COMMAND STRING. The
  path travels as `MEALPLAN_PATH` (set with `--setenv` by the bwrap args),
  content travels on stdin. `realpath -m` canonicalises the requested path —
  including a symbolic link that dangles until its last existing ancestor — in
  the same namespace an agent would plant one in.

  The folder root travels the same way, as `MEALPLAN_WORKSPACE`, and for the
  same reason: it is data, not command text. Under bubblewrap it is always
  `/workspace`, the mount point. Under `MEALPLAN_SANDBOX=host` there is no
  mount and it is the folder's real path, so these scripts are the ONE thing
  both modes share unchanged — the containment check below is the same string
  either way, and only the namespace under it differs. `Mealplan.Sandbox.Runner`
  sets it; nothing else may.
  """

  # Bash's own exit code for "the shell itself failed to start the command".
  @realpath_failed 2
  # Chosen so it collides with nothing cat/mkdir/a builtin returns on its own.
  @outside_folder 3

  def outside_folder_code, do: @outside_folder

  def outside_folder_message(requested) do
    "\"#{requested}\" is outside the meal-plan folder. " <>
      "Paths are relative to the folder root, and a symbolic link that leaves it is not followed."
  end

  @resolve """
  workspace=$(realpath -m -- "$MEALPLAN_WORKSPACE")
  target="$MEALPLAN_PATH"
  case "$target" in
    /*) : ;;
    *) target="$workspace/$target" ;;
  esac
  resolved=$(realpath -m -- "$target") || exit #{@realpath_failed}
  case "$resolved" in
    "$workspace"|"$workspace"/*) : ;;
    *) exit #{@outside_folder} ;;
  esac
  """

  def resolve_script, do: String.trim(@resolve)

  def read_script, do: resolve_script() <> "\ncat -- \"$resolved\"\n"

  def write_script,
    do: resolve_script() <> "\nmkdir -p -- \"$(dirname -- \"$resolved\")\"\ncat > \"$resolved\"\n"

  def stat_script do
    resolve_script() <>
      "\nif [ -d \"$resolved\" ]; then echo dir; elif [ -e \"$resolved\" ]; then echo file; else echo missing; fi\n"
  end

  @doc "List files in the folder root and entries in each of `dirs`. Dotfiles and .gitkeep excluded."
  def list_script(dirs) do
    quoted = dirs |> Enum.map(&shell_quote/1) |> Enum.join(" ")

    """
    w="$MEALPLAN_WORKSPACE"
    for f in "$w"/*; do
      [ -f "$f" ] || continue
      b=$(basename -- "$f")
      case "$b" in .*) continue ;; esac
      printf 'ROOT\\t%s\\n' "$b"
    done
    for d in #{quoted}; do
      [ -d "$w/$d" ] || continue
      for f in "$w/$d"/*; do
        [ -e "$f" ] || continue
        b=$(basename -- "$f")
        case "$b" in .*|.gitkeep) continue ;; esac
        printf '%s\\t%s\\n' "$d" "$b"
      done
    done
    """
  end

  defp shell_quote(word) do
    "'" <> String.replace(to_string(word), "'", "'\\''") <> "'"
  end
end
