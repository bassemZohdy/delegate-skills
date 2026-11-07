#!/usr/bin/env bash
# tests/validate-skills-spec.sh — validate every skill against the agentskills.io
# reference validator (skills-ref).
#
# The skills carry two Claude Code frontmatter extensions that the spec does not
# allow as top-level keys (skills-ref's ALLOWED_FIELDS = name, description,
# license, allowed-tools, metadata, compatibility):
#     disable-model-invocation, argument-hint
# They must stay top-level for Claude Code to honor them, so they are stripped
# from a COPY before validating; everything else must satisfy the spec as-is
# (name == directory, length limits, allowed keys).
#
# Usage:
#   bash tests/validate-skills-spec.sh                # needs the validator on PATH (CI: pip install skills-ref==0.1.1)
#   bash tests/validate-skills-spec.sh --prepare DIR  # only write the stripped copies to DIR
#
# Exit: 0 = all valid, 1 = a skill failed validation, 2 = skills-ref missing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
EXTENSIONS='disable-model-invocation|argument-hint'

prepare() {
  local dest="$1" skill name
  mkdir -p "$dest"
  for skill in "$ROOT"/skills/delegate-to-*/; do
    name=$(basename "$skill")
    rm -rf "${dest:?}/$name"
    cp -R "$skill" "$dest/$name"
    # Drop the extension keys from the frontmatter only (between the first two
    # `---` lines), never from the body.
    awk -v pat="^($EXTENSIONS):" '
      /^---[[:space:]]*$/ { fm++; print; next }
      fm == 1 && $0 ~ pat { next }
      { print }
    ' "$skill/SKILL.md" > "$dest/$name/SKILL.md"
  done
}

if [ "${1:-}" = "--prepare" ]; then
  [ -n "${2:-}" ] || { echo "Usage: validate-skills-spec.sh --prepare DIR" >&2; exit 1; }
  prepare "$2"
  exit 0
fi

# The PyPI package is `skills-ref`; its console script is `agentskills` since
# 0.1.1 (it was `skills-ref` in the source tree). Accept either.
VALIDATOR=""
for candidate in agentskills skills-ref; do
  command -v "$candidate" >/dev/null 2>&1 && { VALIDATOR="$candidate"; break; }
done
[ -n "$VALIDATOR" ] || {
  echo "ERROR: the agentskills.io validator is not installed (python -m pip install skills-ref==0.1.1)." >&2
  exit 2
}
echo "validator: $VALIDATOR"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
prepare "$WORK"

failed=0
for dir in "$WORK"/delegate-to-*/; do
  if "$VALIDATOR" validate "$dir"; then
    echo "valid: $(basename "$dir")"
  else
    echo "INVALID: $(basename "$dir")" >&2
    failed=1
  fi
done
exit "$failed"
