#!/usr/bin/env bash
#
# Migration 2026-08-30: the day directory is "meals/", not "dinners/".
#
# One directory held one dinner per night; now it holds one document per day,
# each documenting any number of meals. Move the day documents into their new
# home and point the folder's own map documents at the new name.
#
# Runs INSIDE the sandbox, exactly as the agent's bash tool runs, at /workspace.
# It is data-independent: any folder that never had a "dinners/" directory is
# already done.

set -euo pipefail

if [ ! -d dinners ]; then
  exit 0
fi

# "meals/" already exists by the time migrations run: the scaffold makes every
# corpus directory before the first migration, so the destination is there.
for f in dinners/*.md; do
  [ -e "$f" ] || continue
  mv "$f" "meals/$(basename "$f")"
done

rm -f dinners/.gitkeep
rmdir dinners 2>/dev/null || true

# README.md and preferences/household.md are the map documents that name the
# directory in prose. Point them at the new name.
sed -i 's#dinners/#meals/#g' README.md preferences/household.md 2>/dev/null || true
