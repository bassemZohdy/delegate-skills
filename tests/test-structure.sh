#!/usr/bin/env bash
# tests/test-structure.sh — validate file structure and content
#
# Can be sourced by run-tests.sh or run standalone.

# Standalone fallback — define helpers if not already defined by parent
if ! declare -f pass &>/dev/null; then
  PASS=0; FAIL=0
  pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
  fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
  PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  _standalone=true
fi

SKILLS=(
  "delegate-to-opencode"
  "delegate-to-pi"
  "delegate-to-mimo"
  "delegate-to-hermes"
  "delegate-to-kimi"
  "delegate-to-codex"
  "delegate-to-agy"
)

# --- Required top-level files ---
for f in README.md AGENTS.md TODO.md .gitignore; do
  if [ -f "$PROJECT_ROOT/$f" ]; then
    pass "Top-level $f exists"
  else
    fail "Top-level $f missing"
  fi
done

# --- Required shared directories ---
for d in docs tests; do
  if [ -d "$PROJECT_ROOT/$d" ]; then
    pass "Shared directory $d/ exists"
  else
    fail "Shared directory $d/ missing"
  fi
done

# --- Required shared files ---
for f in docs/workflow.md docs/usage.md docs/install.md tests/run-tests.sh tests/test-structure.sh; do
  if [ -f "$PROJECT_ROOT/$f" ]; then
    pass "Shared file $f exists"
  else
    fail "Shared file $f missing"
  fi
done

# --- Tool-agnostic adapters ---
for f in scripts/delegate.sh adapters/generic-prompt.md hermes-skills/delegate-tasks/SKILL.md; do
  if [ -f "$PROJECT_ROOT/$f" ]; then
    pass "Adapter file $f exists"
  else
    fail "Adapter file $f missing"
  fi
done

# scripts/delegate.sh must be executable or at least have bash shebang
if [ -f "$PROJECT_ROOT/scripts/delegate.sh" ]; then
  if head -1 "$PROJECT_ROOT/scripts/delegate.sh" | grep -q "bash"; then
    pass "scripts/delegate.sh has bash shebang"
  else
    fail "scripts/delegate.sh missing bash shebang"
  fi
  # Must support all 7 runtimes
  for rt in opencode pi mimo hermes kimi codex agy; do
    if grep -q "$rt)" "$PROJECT_ROOT/scripts/delegate.sh"; then
      pass "scripts/delegate.sh handles runtime: $rt"
    else
      fail "scripts/delegate.sh missing runtime: $rt"
    fi
  done
fi

# hermes SKILL.md must have hermes metadata
if [ -f "$PROJECT_ROOT/hermes-skills/delegate-tasks/SKILL.md" ]; then
  if head -1 "$PROJECT_ROOT/hermes-skills/delegate-tasks/SKILL.md" | grep -q "^---$"; then
    pass "hermes-skills SKILL.md has frontmatter"
  else
    fail "hermes-skills SKILL.md missing frontmatter"
  fi
  if grep -q "hermes:" "$PROJECT_ROOT/hermes-skills/delegate-tasks/SKILL.md"; then
    pass "hermes-skills SKILL.md has hermes metadata"
  else
    fail "hermes-skills SKILL.md missing hermes metadata"
  fi
  if grep -q "terminal(" "$PROJECT_ROOT/hermes-skills/delegate-tasks/SKILL.md"; then
    pass "hermes-skills SKILL.md uses terminal() patterns"
  else
    fail "hermes-skills SKILL.md missing terminal() patterns"
  fi
fi

# src/ should not exist at root (test artifacts from delegated tasks)
if [ -d "$PROJECT_ROOT/src" ]; then
  fail "Root src/ exists (should not — test artifacts must be removed)"
else
  pass "Root src/ correctly absent"
fi

# --- evals/ should NOT exist at root level ---
if [ -d "$PROJECT_ROOT/evals" ]; then
  fail "Root evals/ still exists (should be removed)"
else
  pass "Root evals/ correctly absent"
fi

# --- Per-skill checks ---
for skill in "${SKILLS[@]}"; do
  # SKILL.md exists
  if [ -f "$PROJECT_ROOT/$skill/SKILL.md" ]; then
    pass "$skill/SKILL.md exists"
  else
    fail "$skill/SKILL.md missing"
    continue
  fi

  # Frontmatter delimiter
  if head -1 "$PROJECT_ROOT/$skill/SKILL.md" | grep -q "^---$"; then
    pass "$skill/SKILL.md has frontmatter delimiter"
  else
    fail "$skill/SKILL.md missing frontmatter delimiter"
  fi

  # Correct name field
  if grep -q "^name: $skill" "$PROJECT_ROOT/$skill/SKILL.md"; then
    pass "$skill/SKILL.md has correct name"
  else
    fail "$skill/SKILL.md name field incorrect or missing"
  fi

  # disable-model-invocation
  if grep -q "disable-model-invocation: true" "$PROJECT_ROOT/$skill/SKILL.md"; then
    pass "$skill/SKILL.md has disable-model-invocation: true"
  else
    fail "$skill/SKILL.md missing disable-model-invocation: true"
  fi

  # References Step 4
  if grep -q "Step 4" "$PROJECT_ROOT/$skill/SKILL.md"; then
    pass "$skill/SKILL.md defines Step 4"
  else
    fail "$skill/SKILL.md missing Step 4 content"
  fi

  # References shared workflow
  if grep -q "docs/workflow.md" "$PROJECT_ROOT/$skill/SKILL.md"; then
    pass "$skill/SKILL.md references docs/workflow.md"
  else
    fail "$skill/SKILL.md missing workflow reference"
  fi

  # No duplicate Step 0 (belongs in workflow.md only)
  if grep -q "Step 0: Git Preflight" "$PROJECT_ROOT/$skill/SKILL.md"; then
    fail "$skill/SKILL.md contains duplicate Step 0 (should be in workflow.md only)"
  else
    pass "$skill/SKILL.md has no duplicate Step 0"
  fi

  # No unfilled TASK-N placeholder in launch commands
  if grep -q '"TASK-N"' "$PROJECT_ROOT/$skill/SKILL.md" 2>/dev/null || \
     grep -qE "worktrees/TASK-N|tasks/TASK-N" "$PROJECT_ROOT/$skill/SKILL.md"; then
    pass "$skill/SKILL.md contains TASK-N template placeholders (expected)"
  fi

  # Stale nested directories should not exist
  for subdir in references evals; do
    if [ -d "$PROJECT_ROOT/$skill/$subdir" ]; then
      fail "$skill/$subdir/ should not exist"
    else
      pass "$skill/$subdir/ correctly absent"
    fi
  done

  # Stale README.md should not exist at skill level
  if [ -f "$PROJECT_ROOT/$skill/README.md" ]; then
    fail "$skill/README.md should not exist (docs are at repo level)"
  else
    pass "$skill/README.md correctly absent"
  fi

  # missing_runtime JSON block must be present
  if grep -q "missing_runtime" "$PROJECT_ROOT/$skill/SKILL.md"; then
    pass "$skill/SKILL.md has missing_runtime abort block"
  else
    fail "$skill/SKILL.md missing the missing_runtime abort block"
  fi

  # Retry section must be present
  if grep -q "Retry" "$PROJECT_ROOT/$skill/SKILL.md"; then
    pass "$skill/SKILL.md has Retry section"
  else
    fail "$skill/SKILL.md missing Retry section"
  fi
done

# --- workflow.md completeness ---
for step in "Step 0" "Step 1" "Step 2" "Step 3" "Step 5"; do
  if grep -q "$step" "$PROJECT_ROOT/docs/workflow.md"; then
    pass "workflow.md contains $step"
  else
    fail "workflow.md missing $step"
  fi
done

if grep -q "Step 4: Detect Runtime" "$PROJECT_ROOT/docs/workflow.md"; then
  if grep -q "This step is runtime-specific" "$PROJECT_ROOT/docs/workflow.md"; then
    pass "workflow.md Step 4 is a reference stub only (correct)"
  else
    fail "workflow.md contains full Step 4 content (should be per-skill only)"
  fi
fi

# --- docs/ install instruction covers docs/ layout ---
if grep -q "cp -r docs" "$PROJECT_ROOT/README.md" || grep -q "ln -s.*docs" "$PROJECT_ROOT/README.md"; then
  pass "README.md instructs users to install docs/ alongside skills"
else
  fail "README.md missing docs/ install instruction (skills reference ../docs/workflow.md)"
fi

# --- install.md covers multiple Claude Code interfaces ---
if [ -f "$PROJECT_ROOT/docs/install.md" ]; then
  for interface in "CLI" "VS Code" "JetBrains" "Desktop" "claude.ai"; do
    if grep -qi "$interface" "$PROJECT_ROOT/docs/install.md"; then
      pass "install.md covers $interface"
    else
      fail "install.md missing $interface section"
    fi
  done
fi

# --- AGENTS.md CLI table covers all skills ---
for skill in "${SKILLS[@]}"; do
  runtime="${skill#delegate-to-}"
  if grep -q "$runtime" "$PROJECT_ROOT/AGENTS.md"; then
    pass "AGENTS.md references $runtime"
  else
    fail "AGENTS.md missing $runtime entry"
  fi
done

# --- Shell scripts have bash shebang ---
for script in tests/run-tests.sh tests/test-structure.sh; do
  if [ -f "$PROJECT_ROOT/$script" ]; then
    if head -1 "$PROJECT_ROOT/$script" | grep -q "bash"; then
      pass "$script has bash shebang"
    else
      fail "$script missing bash shebang"
    fi
  fi
done

# Standalone summary
if [ "${_standalone:-false}" = "true" ]; then
  echo ""
  echo "  $PASS passed, $FAIL failed"
  [ "$FAIL" -gt 0 ] && exit 1 || exit 0
fi
