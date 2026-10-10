#!/usr/bin/env bash
# skills/ is authoritative; copies stay self-contained for single-skill installs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
MODE="${1:-}"
case "$MODE" in ""|--check) ;; *) echo "Usage: sync-skills.sh [--check]" >&2; exit 1 ;; esac
if [ "$MODE" = --check ]; then
  for skill in "$ROOT"/skills/delegate-to-*; do
    cmp "$ROOT/skills/shared/workflow.md" "$skill/workflow.md"
  done
  diff -r "$ROOT/skills" "$ROOT/.agents/skills"
  echo "Skill distributions match canonical sources."
else
  for path in "$ROOT/.agents" "$ROOT/.agents/skills"; do
    [ ! -L "$path" ] || { echo "ERROR: mirror directories must not be symlinks" >&2; exit 1; }
  done
  if [ -d "$ROOT/.agents/skills" ] && [ -n "$(find "$ROOT/.agents/skills" -type l -print)" ]; then
    echo "ERROR: mirrored skill paths must not be symlinks" >&2
    exit 1
  fi
  for skill in "$ROOT"/skills/delegate-to-*; do
    cp "$ROOT/skills/shared/workflow.md" "$skill/workflow.md"
  done
  mkdir -p "$ROOT/.agents/skills"
  cp -R "$ROOT/skills/." "$ROOT/.agents/skills/"
  # Do not silently delete unexpected files. Report any stale extras for review.
  bash "$0" --check
fi
