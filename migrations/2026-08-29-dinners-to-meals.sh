#!/usr/bin/env bash
#
# Migration 2026-08-29: one-dinner days become days of meals.
#
# The old shape held one dinner per day, with `servings:` in the front matter
# and recipe links under `## Recipes` and prose under `## Notes`. The new shape
# holds any number of meals per day: each meal is a `## <name>` section, links
# sit directly under it, and a `servings:` line belongs to the meal it feeds.
# A day whose only content was notes becomes a day with no meals at all.
#
# This runs INSIDE the sandbox, exactly as the agent's own bash tool runs, on
# /workspace. It is deliberately data-independent: it reads every dinner and
# rewrites only the ones still in the old shape, and `## Recipes`/`## Notes`
# will not be there afterwards, so it is safe to run again although the
# migration ledger means it never needs to.

set -euo pipefail

for f in dinners/*.md; do
  # No matches -> `dinners/*.md` is a literal, which does not exist.
  [ -e "$f" ] || continue

  # Only the old shape. A file already holding meals has neither heading.
  if ! grep -qE '^## (Recipes|Notes)[[:space:]]*$' "$f"; then
    continue
  fi

  date="$(awk '/^date:/{print $2; exit}' "$f")"
  servings="$(awk '/^servings:/{print $2; exit}' "$f" || true)"

  # The day title is prose the validator never reads, so if `date -d` is
  # unavailable the ISO date alone is a fine fallback.
  title="$(date -d "$date" '+%A, %B %-d, %Y' 2>/dev/null || printf '%s' "$date")"

  awk -v date="$date" -v servings="$servings" -v title="$title" '
    BEGIN { inrec = 0; innote = 0; recipes = ""; notes = ""; }
    /^## Recipes[[:space:]]*$/ { inrec = 1; innote = 0; next }
    /^## Notes[[:space:]]*$/   { inrec = 0; innote = 1; next }
    /^## /                       { inrec = 0; innote = 0; next }
    inrec {
      if ($0 ~ /^[[:space:]]*- \[[^]]*\]\([^)]*\)[[:space:]]*$/) {
        recipes = recipes "\n" $0
      }
      next
    }
    innote {
      if ($0 !~ /^[[:space:]]*$/) {
        notes = notes "\n" $0
      }
      next
    }
    END {
      printf "---\ndate: %s\n---\n\n# Meals for %s\n\n", date, title
      if (recipes != "") {
        print "## Dinner"
        print ""
        if (servings != "") {
          print "servings: " servings
          print ""
        }
        printf "%s\n", substr(recipes, 2)
        if (notes != "") {
          print ""
          printf "%s\n", substr(notes, 2)
        }
      } else if (notes != "") {
        printf "%s\n", substr(notes, 2)
      }
    }
  ' "$f" > "$f.new"

  mv "$f.new" "$f"
done
