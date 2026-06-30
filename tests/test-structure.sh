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
  "delegate-to-any"
  "delegate-to-opencode"
  "delegate-to-pi"
  "delegate-to-mimo"
  "delegate-to-hermes"
  "delegate-to-kimi"
  "delegate-to-codex"
  "delegate-to-agy"
)

RUNTIMES=( opencode pi mimo hermes kimi codex agy )

# ─── Required top-level files ─────────────────────────────────────────────────

for f in README.md AGENTS.md TODO.md .gitignore; do
  [ -f "$PROJECT_ROOT/$f" ] \
    && pass "Top-level $f exists" \
    || fail "Top-level $f missing"
done

# ─── Required top-level directories ──────────────────────────────────────────

for d in skills helpers docs tests; do
  [ -d "$PROJECT_ROOT/$d" ] \
    && pass "Top-level directory $d/ exists" \
    || fail "Top-level directory $d/ missing"
done

# ─── skills/shared/ — shared skill resources ──────────────────────────────────

[ -d "$PROJECT_ROOT/skills/shared" ] \
  && pass "skills/shared/ directory exists" \
  || fail "skills/shared/ directory missing"

[ -f "$PROJECT_ROOT/skills/shared/workflow.md" ] \
  && pass "skills/shared/workflow.md exists" \
  || fail "skills/shared/workflow.md missing (moved from docs/)"

# workflow.md must NOT live in docs/ (docs is for documentation only)
[ -f "$PROJECT_ROOT/docs/workflow.md" ] \
  && fail "docs/workflow.md should not exist (belongs in skills/shared/)" \
  || pass "docs/workflow.md correctly absent (it lives in skills/shared/)"

# ─── docs/ — documentation only ───────────────────────────────────────────────

for f in docs/usage.md docs/install.md; do
  [ -f "$PROJECT_ROOT/$f" ] \
    && pass "$f exists" \
    || fail "$f missing"
done

# ─── tests/ — at repo root ────────────────────────────────────────────────────

for f in tests/run-tests.sh tests/test-structure.sh; do
  [ -f "$PROJECT_ROOT/$f" ] \
    && pass "$f exists" \
    || fail "$f missing"
done

# ─── helpers/ — setup and configure helpers ───────────────────────────────────

for f in helpers/scripts/delegate.sh \
         helpers/adapters/generic-prompt.md \
         helpers/hermes/delegate-tasks/SKILL.md; do
  [ -f "$PROJECT_ROOT/$f" ] \
    && pass "$f exists" \
    || fail "$f missing"
done

# ─── helpers/scripts/delegate.sh deep checks ──────────────────────────────────

DELEGATE_SH="$PROJECT_ROOT/helpers/scripts/delegate.sh"
if [ -f "$DELEGATE_SH" ]; then

  head -1 "$DELEGATE_SH" | grep -q "bash" \
    && pass "helpers/scripts/delegate.sh has bash shebang" \
    || fail "helpers/scripts/delegate.sh missing bash shebang"

  grep -q "set -euo pipefail" "$DELEGATE_SH" \
    && pass "helpers/scripts/delegate.sh has strict mode (set -euo pipefail)" \
    || fail "helpers/scripts/delegate.sh missing strict mode"

  grep -q "not found\|Handoff document\|TASK_FILE" "$DELEGATE_SH" \
    && grep -q "\-f.*TASK_FILE\|TASK_FILE.*\-f\|not found" "$DELEGATE_SH" \
    && pass "helpers/scripts/delegate.sh has handoff file preflight check" \
    || fail "helpers/scripts/delegate.sh missing handoff file preflight"

  grep -q "command -v" "$DELEGATE_SH" \
    && pass "helpers/scripts/delegate.sh checks runtime is on PATH" \
    || fail "helpers/scripts/delegate.sh missing runtime-on-PATH check"

  grep -q 'echo "PID=' "$DELEGATE_SH" \
    && pass "helpers/scripts/delegate.sh outputs PID=" \
    || fail "helpers/scripts/delegate.sh missing PID= output line"

  grep -q 'echo "LOG=' "$DELEGATE_SH" \
    && pass "helpers/scripts/delegate.sh outputs LOG=" \
    || fail "helpers/scripts/delegate.sh missing LOG= output line"

  grep -q 'echo "WORK_DIR=' "$DELEGATE_SH" \
    && pass "helpers/scripts/delegate.sh outputs WORK_DIR=" \
    || fail "helpers/scripts/delegate.sh missing WORK_DIR= output line"

  grep -q "watchdog" "$DELEGATE_SH" \
    && pass "helpers/scripts/delegate.sh has watchdog setup" \
    || fail "helpers/scripts/delegate.sh missing watchdog"

  grep -q "MIMO_HELP" "$DELEGATE_SH" \
    && pass "helpers/scripts/delegate.sh caches mimo --help output (MIMO_HELP)" \
    || fail "helpers/scripts/delegate.sh should cache mimo --help"

  for rt in "${RUNTIMES[@]}"; do
    grep -q "$rt)" "$DELEGATE_SH" \
      && pass "helpers/scripts/delegate.sh handles runtime: $rt" \
      || fail "helpers/scripts/delegate.sh missing runtime case: $rt"
  done

fi

# ─── helpers/hermes/delegate-tasks/SKILL.md deep checks ──────────────────────

HERMES_SKILL="$PROJECT_ROOT/helpers/hermes/delegate-tasks/SKILL.md"
if [ -f "$HERMES_SKILL" ]; then

  head -1 "$HERMES_SKILL" | grep -q "^---$" \
    && pass "helpers/hermes SKILL.md has frontmatter" \
    || fail "helpers/hermes SKILL.md missing frontmatter"

  grep -q "hermes:" "$HERMES_SKILL" \
    && pass "helpers/hermes SKILL.md has hermes: metadata" \
    || fail "helpers/hermes SKILL.md missing hermes: metadata"

  grep -q "terminal(" "$HERMES_SKILL" \
    && pass "helpers/hermes SKILL.md uses terminal() API patterns" \
    || fail "helpers/hermes SKILL.md missing terminal() patterns"

  for rt in "${RUNTIMES[@]}"; do
    grep -q "$rt" "$HERMES_SKILL" \
      && pass "helpers/hermes SKILL.md covers runtime: $rt" \
      || fail "helpers/hermes SKILL.md missing runtime: $rt"
  done

  grep -q "delegate.sh\|scripts/" "$HERMES_SKILL" \
    && pass "helpers/hermes SKILL.md references delegate.sh script" \
    || fail "helpers/hermes SKILL.md missing delegate.sh reference"

  grep -q "watchdog\|timeout\|TIMEOUT" "$HERMES_SKILL" \
    && pass "helpers/hermes SKILL.md covers timeout / watchdog" \
    || fail "helpers/hermes SKILL.md missing timeout/watchdog coverage"

fi

# ─── Root artifact checks ─────────────────────────────────────────────────────

[ -d "$PROJECT_ROOT/src" ] \
  && fail "Root src/ exists (test artifacts must be removed)" \
  || pass "Root src/ correctly absent"

[ -d "$PROJECT_ROOT/evals" ] \
  && fail "Root evals/ still exists (should be removed)" \
  || pass "Root evals/ correctly absent"

# Old top-level skill dirs must not exist at root
for skill in "${SKILLS[@]}"; do
  [ -d "$PROJECT_ROOT/$skill" ] \
    && fail "$skill/ exists at root (should be under skills/)" \
    || pass "$skill/ correctly absent from root"
done

# ─── Per-skill checks ─────────────────────────────────────────────────────────

for skill in "${SKILLS[@]}"; do
  SKILL_FILE="$PROJECT_ROOT/skills/$skill/SKILL.md"

  if [ ! -f "$SKILL_FILE" ]; then
    fail "skills/$skill/SKILL.md missing"
    continue
  fi
  pass "skills/$skill/SKILL.md exists"

  # Frontmatter
  head -1 "$SKILL_FILE" | grep -q "^---$" \
    && pass "skills/$skill/SKILL.md has frontmatter delimiter" \
    || fail "skills/$skill/SKILL.md missing frontmatter delimiter"

  grep -q "^name: $skill" "$SKILL_FILE" \
    && pass "skills/$skill/SKILL.md has correct name field" \
    || fail "skills/$skill/SKILL.md name field incorrect or missing"

  grep -q "disable-model-invocation: true" "$SKILL_FILE" \
    && pass "skills/$skill/SKILL.md has disable-model-invocation: true" \
    || fail "skills/$skill/SKILL.md missing disable-model-invocation: true"

  # agentskills.io spec required fields (cross-tool compatibility)
  grep -q "^license:" "$SKILL_FILE" \
    && pass "skills/$skill/SKILL.md has license field (agentskills spec)" \
    || fail "skills/$skill/SKILL.md missing license field (agentskills spec)"

  grep -q "^compatibility:" "$SKILL_FILE" \
    && pass "skills/$skill/SKILL.md has compatibility field (agentskills spec)" \
    || fail "skills/$skill/SKILL.md missing compatibility field (agentskills spec)"

  grep -q "^metadata:" "$SKILL_FILE" \
    && pass "skills/$skill/SKILL.md has metadata block (agentskills spec)" \
    || fail "skills/$skill/SKILL.md missing metadata block (agentskills spec)"

  grep -q "author:" "$SKILL_FILE" \
    && pass "skills/$skill/SKILL.md metadata has author key" \
    || fail "skills/$skill/SKILL.md metadata missing author key"

  grep -q "version:" "$SKILL_FILE" \
    && pass "skills/$skill/SKILL.md metadata has version key" \
    || fail "skills/$skill/SKILL.md metadata missing version key"

  grep -q "category:" "$SKILL_FILE" \
    && pass "skills/$skill/SKILL.md metadata has category key" \
    || fail "skills/$skill/SKILL.md metadata missing category key"

  # agentskills spec field ordering: spec fields before tool-specific extensions
  awk '/^license:/{lic=NR} /^disable-model-invocation:/{dim=NR} END{exit (lic>0 && dim>0 && lic<dim) ? 0 : 1}' "$SKILL_FILE" \
    && pass "skills/$skill/SKILL.md spec fields appear before tool-specific extensions" \
    || fail "skills/$skill/SKILL.md spec fields should come before disable-model-invocation"

  # Claude Code / pi extensions
  grep -q "argument-hint:" "$SKILL_FILE" \
    && pass "skills/$skill/SKILL.md has argument-hint field" \
    || fail "skills/$skill/SKILL.md missing argument-hint field"

  grep -q 'task description' "$SKILL_FILE" \
    && pass "skills/$skill/SKILL.md argument-hint describes expected input" \
    || fail "skills/$skill/SKILL.md argument-hint missing 'task description' label"

  # Step 4 structure
  grep -q "Step 4" "$SKILL_FILE" \
    && pass "skills/$skill/SKILL.md defines Step 4" \
    || fail "skills/$skill/SKILL.md missing Step 4 content"

  grep -q "shared/workflow.md" "$SKILL_FILE" \
    && pass "skills/$skill/SKILL.md references shared/workflow.md" \
    || fail "skills/$skill/SKILL.md missing shared/workflow.md reference"

  # Must use correct relative path: skill is one level below skills/
  grep -q '\.\./shared/workflow\.md' "$SKILL_FILE" \
    && pass "skills/$skill/SKILL.md uses correct ../shared/workflow.md path" \
    || fail "skills/$skill/SKILL.md has wrong workflow path (must be ../shared/workflow.md)"

  # Must NOT reference the old docs/ path
  grep -q '\.\./docs/workflow\.md' "$SKILL_FILE" \
    && fail "skills/$skill/SKILL.md has stale ../docs/workflow.md reference" \
    || pass "skills/$skill/SKILL.md has no stale ../docs/workflow.md reference"

  # Step 0 must not be duplicated here
  grep -q "Step 0: Git Preflight" "$SKILL_FILE" \
    && fail "skills/$skill/SKILL.md duplicates Step 0 (belongs in shared/workflow.md only)" \
    || pass "skills/$skill/SKILL.md has no duplicate Step 0"

  # $ARGUMENTS must be embedded so the task description flows into the workflow
  grep -q '\$ARGUMENTS' "$SKILL_FILE" \
    && pass "skills/$skill/SKILL.md embeds \$ARGUMENTS (task description)" \
    || fail "skills/$skill/SKILL.md missing \$ARGUMENTS placeholder"

  # TASK-N path placeholders
  grep -qE "worktrees/TASK-N|tasks/TASK-N" "$SKILL_FILE" \
    && pass "skills/$skill/SKILL.md has TASK-N path placeholders" \
    || fail "skills/$skill/SKILL.md missing TASK-N path placeholders"

  # Launch block essentials
  grep -q "nohup" "$SKILL_FILE" \
    && pass "skills/$skill/SKILL.md uses nohup for background launch" \
    || fail "skills/$skill/SKILL.md missing nohup"

  grep -q "watchdog.pid" "$SKILL_FILE" \
    && pass "skills/$skill/SKILL.md writes watchdog PID file" \
    || fail "skills/$skill/SKILL.md missing watchdog.pid"

  grep -q "TASK-N.pid" "$SKILL_FILE" \
    && pass "skills/$skill/SKILL.md writes agent PID file" \
    || fail "skills/$skill/SKILL.md missing TASK-N.pid write"

  grep -q "TASK-N.retries" "$SKILL_FILE" \
    && pass "skills/$skill/SKILL.md initialises retries file" \
    || fail "skills/$skill/SKILL.md missing TASK-N.retries"

  grep -q "TASK-N.log" "$SKILL_FILE" \
    && pass "skills/$skill/SKILL.md redirects output to log file" \
    || fail "skills/$skill/SKILL.md missing TASK-N.log redirect"

  # Abort block and retry
  grep -q "missing_runtime" "$SKILL_FILE" \
    && pass "skills/$skill/SKILL.md has missing_runtime abort block" \
    || fail "skills/$skill/SKILL.md missing the missing_runtime abort block"

  grep -q "Retry" "$SKILL_FILE" \
    && pass "skills/$skill/SKILL.md has Retry section" \
    || fail "skills/$skill/SKILL.md missing Retry section"

  # Stale artifacts inside skill dir
  for subdir in references evals docs; do
    [ -d "$PROJECT_ROOT/skills/$skill/$subdir" ] \
      && fail "skills/$skill/$subdir/ should not exist" \
      || pass "skills/$skill/$subdir/ correctly absent"
  done

  [ -f "$PROJECT_ROOT/skills/$skill/README.md" ] \
    && fail "skills/$skill/README.md should not exist (docs are at repo root)" \
    || pass "skills/$skill/README.md correctly absent"

  # ── Runtime-specific content checks ─────────────────────────────────────────

  case "$skill" in

    delegate-to-any)
      for bin in oh-my-opencode opencode pi mimo hermes kimi codex agy; do
        grep -q "$bin" "$SKILL_FILE" \
          && pass "skills/$skill/SKILL.md includes $bin in runtime scan" \
          || fail "skills/$skill/SKILL.md missing $bin from runtime scan"
      done
      grep -qi "priority" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md has priority selection table" \
        || fail "skills/$skill/SKILL.md missing priority selection table"
      grep -q "omo" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md uses 'omo' label for oh-my-opencode" \
        || fail "skills/$skill/SKILL.md missing 'omo' label for oh-my-opencode"
      ;;

    delegate-to-opencode)
      grep -q "oh-my-opencode\|opencode" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md detects opencode / oh-my-opencode" \
        || fail "skills/$skill/SKILL.md missing opencode binary detection"
      grep -q -- "--dangerously-skip-permissions" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md uses --dangerously-skip-permissions" \
        || fail "skills/$skill/SKILL.md missing --dangerously-skip-permissions"
      grep -q -- "--file" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md delivers handoff via --file" \
        || fail "skills/$skill/SKILL.md missing --file handoff delivery"
      grep -q -- "--dir" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md sets working directory via --dir" \
        || fail "skills/$skill/SKILL.md missing --dir flag"
      grep -q -- "--continue" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md retry uses --continue" \
        || fail "skills/$skill/SKILL.md retry missing --continue"
      ;;

    delegate-to-pi)
      grep -q "command -v pi" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md detects pi binary" \
        || fail "skills/$skill/SKILL.md missing 'command -v pi' detection"
      grep -q -- "--approve" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md uses --approve" \
        || fail "skills/$skill/SKILL.md missing --approve flag"
      grep -qE '@\$PROJECT_ROOT|@.*\.opencode' "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md delivers handoff via @ file reference" \
        || fail "skills/$skill/SKILL.md missing @ file reference"
      grep -qE 'PROJECT_ROOT.*=.*\$\(pwd\)|PROJECT_ROOT="\$\(pwd\)"' "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md captures PROJECT_ROOT before cd" \
        || fail "skills/$skill/SKILL.md missing PROJECT_ROOT capture"
      grep -q -- "--continue" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md retry uses --continue" \
        || fail "skills/$skill/SKILL.md retry missing --continue"
      ;;

    delegate-to-mimo)
      grep -q "command -v mimo" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md detects mimo binary" \
        || fail "skills/$skill/SKILL.md missing 'command -v mimo' detection"
      grep -q "mimo run --help" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md checks mimo flags at runtime via --help" \
        || fail "skills/$skill/SKILL.md missing runtime flag detection (mimo run --help)"
      grep -q -- "--dangerously-skip-permissions" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md references --dangerously-skip-permissions" \
        || fail "skills/$skill/SKILL.md missing --dangerously-skip-permissions"
      grep -q -- "--continue" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md retry uses --continue" \
        || fail "skills/$skill/SKILL.md retry missing --continue"
      ;;

    delegate-to-hermes)
      grep -q "command -v hermes" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md detects hermes binary" \
        || fail "skills/$skill/SKILL.md missing 'command -v hermes' detection"
      grep -q -- "--yolo" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md uses --yolo" \
        || fail "skills/$skill/SKILL.md missing --yolo flag"
      grep -q -- "--accept-hooks" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md uses --accept-hooks" \
        || fail "skills/$skill/SKILL.md missing --accept-hooks flag"
      grep -q -- " -Q\b\| -Q " "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md uses -Q (quiet / non-interactive)" \
        || fail "skills/$skill/SKILL.md missing -Q flag"
      grep -qE 'PROJECT_ROOT.*=.*\$\(pwd\)|PROJECT_ROOT="\$\(pwd\)"' "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md captures PROJECT_ROOT before cd" \
        || fail "skills/$skill/SKILL.md missing PROJECT_ROOT capture"
      grep -q -- "--continue" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md retry uses --continue" \
        || fail "skills/$skill/SKILL.md retry missing --continue"
      ;;

    delegate-to-kimi)
      grep -q "command -v kimi" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md detects kimi binary" \
        || fail "skills/$skill/SKILL.md missing 'command -v kimi' detection"
      grep -q -- " -y" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md uses -y (auto-approve)" \
        || fail "skills/$skill/SKILL.md missing -y flag"
      grep -qE 'PROJECT_ROOT.*=.*\$\(pwd\)|PROJECT_ROOT="\$\(pwd\)"' "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md captures PROJECT_ROOT before cd" \
        || fail "skills/$skill/SKILL.md missing PROJECT_ROOT capture"
      grep -qE -- '--continue| -C ' "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md retry uses --continue / -C" \
        || fail "skills/$skill/SKILL.md retry missing --continue / -C"
      ;;

    delegate-to-codex)
      grep -q "command -v codex" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md detects codex binary" \
        || fail "skills/$skill/SKILL.md missing 'command -v codex' detection"
      grep -q "_CODEX_TASK_FILE" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md delivers handoff via stdin (_CODEX_TASK_FILE)" \
        || fail "skills/$skill/SKILL.md missing stdin handoff delivery"
      grep -q -- "--dangerously-bypass-approvals-and-sandbox" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md uses --dangerously-bypass-approvals-and-sandbox" \
        || fail "skills/$skill/SKILL.md missing --dangerously-bypass-approvals-and-sandbox"
      grep -q "_CODEX_WORK_DIR" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md exports _CODEX_WORK_DIR env var" \
        || fail "skills/$skill/SKILL.md missing _CODEX_WORK_DIR env var"
      grep -q "exec resume --last\|resume.*--last" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md retry uses 'codex exec resume --last'" \
        || fail "skills/$skill/SKILL.md retry missing 'exec resume --last'"
      ;;

    delegate-to-agy)
      grep -q "command -v agy" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md detects agy binary" \
        || fail "skills/$skill/SKILL.md missing 'command -v agy' detection"
      grep -q -- "--add-dir" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md uses --add-dir for workspace" \
        || fail "skills/$skill/SKILL.md missing --add-dir flag"
      grep -q -- "--print" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md uses --print for non-interactive mode" \
        || fail "skills/$skill/SKILL.md missing --print flag"
      grep -q -- "--dangerously-skip-permissions" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md uses --dangerously-skip-permissions" \
        || fail "skills/$skill/SKILL.md missing --dangerously-skip-permissions"
      grep -q -- "--continue" "$SKILL_FILE" \
        && pass "skills/$skill/SKILL.md retry uses --continue" \
        || fail "skills/$skill/SKILL.md retry missing --continue"
      ;;

  esac

done

# ─── skills/shared/workflow.md completeness ───────────────────────────────────

WORKFLOW="$PROJECT_ROOT/skills/shared/workflow.md"

for step in "Step 0" "Step 1" "Step 2" "Step 3" "Step 5"; do
  grep -q "$step" "$WORKFLOW" \
    && pass "shared/workflow.md contains $step" \
    || fail "shared/workflow.md missing $step"
done

if grep -q "Step 4: Detect Runtime" "$WORKFLOW"; then
  grep -q "This step is runtime-specific" "$WORKFLOW" \
    && pass "shared/workflow.md Step 4 is a reference stub only (correct)" \
    || fail "shared/workflow.md Step 4 has full content (must be a stub)"
fi

for case_n in "Case 1" "Case 2" "Case 3" "Case 4" "Case 5"; do
  grep -q "$case_n" "$WORKFLOW" \
    && pass "shared/workflow.md covers self-healing $case_n" \
    || fail "shared/workflow.md missing self-healing $case_n"
done

grep -q "active_form" "$WORKFLOW" \
  && pass "shared/workflow.md documents the active_form field" \
  || fail "shared/workflow.md missing active_form documentation"

grep -q "owner" "$WORKFLOW" \
  && pass "shared/workflow.md documents the owner field" \
  || fail "shared/workflow.md missing owner field documentation"

grep -q "retries" "$WORKFLOW" \
  && pass "shared/workflow.md documents the retries field" \
  || fail "shared/workflow.md missing retries field documentation"

grep -qE "SIGTERM|watchdog|kill -" "$WORKFLOW" \
  && pass "shared/workflow.md covers timeout / watchdog handling" \
  || fail "shared/workflow.md missing timeout/watchdog handling"

# ─── docs/ completeness ───────────────────────────────────────────────────────

USAGE="$PROJECT_ROOT/docs/usage.md"
if [ -f "$USAGE" ]; then
  grep -q "delegate-to-any" "$USAGE" \
    && pass "docs/usage.md references /delegate-to-any" \
    || fail "docs/usage.md missing /delegate-to-any"

  grep -qi "tier" "$USAGE" \
    && pass "docs/usage.md has timeout tiers table" \
    || fail "docs/usage.md missing timeout tiers"

  grep -q "git merge" "$USAGE" \
    && pass "docs/usage.md includes merge command" \
    || fail "docs/usage.md missing merge command"

  for rt in "${RUNTIMES[@]}"; do
    grep -q "delegate-to-$rt" "$USAGE" \
      && pass "docs/usage.md lists /delegate-to-$rt" \
      || fail "docs/usage.md missing /delegate-to-$rt"
  done
fi

INSTALL="$PROJECT_ROOT/docs/install.md"
if [ -f "$INSTALL" ]; then
  for interface in "CLI" "VS Code" "JetBrains" "Desktop" "claude.ai"; do
    grep -qi "$interface" "$INSTALL" \
      && pass "docs/install.md covers $interface" \
      || fail "docs/install.md missing $interface section"
  done

  grep -q "agents/skills" "$INSTALL" \
    && pass "docs/install.md documents ~/.agents/skills/ cross-tool path" \
    || fail "docs/install.md missing ~/.agents/skills/ cross-tool path"

  grep -qi "agentskills\|agentskills\.io" "$INSTALL" \
    && pass "docs/install.md references agentskills.io standard" \
    || fail "docs/install.md missing agentskills.io reference"

  for tool in "OpenCode" "Codex" "Gemini" "Kimi" "Hermes"; do
    grep -qi "$tool" "$INSTALL" \
      && pass "docs/install.md has $tool install section" \
      || fail "docs/install.md missing $tool install section"
  done
fi

# ─── README.md checks ─────────────────────────────────────────────────────────

grep -qE "cp -r.*skills|ln -s.*skills" "$PROJECT_ROOT/README.md" \
  && pass "README.md instructs users to install from skills/" \
  || fail "README.md missing skills/ install instruction"

grep -q "delegate-to-any" "$PROJECT_ROOT/README.md" \
  && pass "README.md references delegate-to-any" \
  || fail "README.md missing delegate-to-any"

grep -q "agents/skills" "$PROJECT_ROOT/README.md" \
  && pass "README.md documents ~/.agents/skills/ cross-tool path" \
  || fail "README.md missing ~/.agents/skills/ cross-tool path"

grep -qi "agentskills\|agentskills\.io" "$PROJECT_ROOT/README.md" \
  && pass "README.md references agentskills.io standard" \
  || fail "README.md missing agentskills.io reference"

# ─── AGENTS.md coverage ───────────────────────────────────────────────────────

for skill in "${SKILLS[@]}"; do
  runtime="${skill#delegate-to-}"
  grep -q "$runtime" "$PROJECT_ROOT/AGENTS.md" \
    && pass "AGENTS.md references $runtime" \
    || fail "AGENTS.md missing $runtime entry"
done

grep -qi "known gotcha\|gotcha" "$PROJECT_ROOT/AGENTS.md" \
  && pass "AGENTS.md has Known gotchas section" \
  || fail "AGENTS.md missing Known gotchas section"

grep -q "CLI differences\|Run command" "$PROJECT_ROOT/AGENTS.md" \
  && pass "AGENTS.md has CLI differences table" \
  || fail "AGENTS.md missing CLI differences table"

# ─── Shell script shebangs ────────────────────────────────────────────────────

for script in tests/run-tests.sh tests/test-structure.sh helpers/scripts/delegate.sh; do
  if [ -f "$PROJECT_ROOT/$script" ]; then
    head -1 "$PROJECT_ROOT/$script" | grep -q "bash" \
      && pass "$script has bash shebang" \
      || fail "$script missing bash shebang"
  fi
done

# ─── Semantic regression tests ────────────────────────────────────────────────
# These assert behavioral correctness of previously-found bugs, not just string
# presence. The structure tests above are grep-only and would pass even with the
# bugs present; this block prevents silent regressions.

echo ""
echo "  ─── semantic regression checks ───"

# Regression: omo (oh-my-opencode) launch block must set the working directory.
# Bug #1 — omo ran in the project root, ignoring the worktree, because neither
# --dir nor a cd fallback was present. Both the opencode path and omo path must
# isolate into WORK_DIR.
for skill in delegate-to-opencode delegate-to-any; do
  F="$PROJECT_ROOT/skills/$skill/SKILL.md"

  # Extract the omo launch block (from "oh-my-opencode run" to the next blank
  # fenced block boundary) and assert it touches WORK_DIR via --dir or cd.
  if awk '/oh-my-opencode run/{flag=1} flag{print} /--yes \\/{if(flag)exit}' "$F" \
       | grep -qE -- '--dir|\bcd "\$WORK_DIR"'; then
    pass "skills/$skill/SKILL.md omo block sets working dir (--dir or cd)"
  else
    fail "skills/$skill/SKILL.md omo block does NOT set working dir (regression of bug #1)"
  fi
done

# Regression: cd-based runtimes in delegate.sh must capture the real nohup PID,
# not a subshell PID. Bug #3 — `( cd ... && nohup ... & )` made $! the subshell.
# Assert none of the cd-based runtimes wrap the backgrounded nohup in `( ... ) &`.
DELEGATE_SH="$PROJECT_ROOT/helpers/scripts/delegate.sh"
for rt in pi hermes kimi; do
  # Find the case body for this runtime and check no `& )` subshell-background
  # pattern wraps nohup. We look for the runtime's case up to the next `;;`.
  if awk -v rt="$rt" '
        $0 ~ "^  "rt")" {incase=1}
        incase {print}
        /;;/ && incase {incase=0; exit}
      ' "$DELEGATE_SH" | grep -qE '\)&[[:space:]]*$|&\s*\)'; then
    fail "helpers/scripts/delegate.sh '$rt' case backgrounds a subshell (regression of bug #3)"
  else
    pass "helpers/scripts/delegate.sh '$rt' case captures real agent PID (no subshell)"
  fi
done

# Regression: delegate.sh must initialise the .retries file for parity with the
# SKILL.md inline launch blocks (Step 5 Case 1 reads it).
grep -q 'retries' "$DELEGATE_SH" \
  && pass "helpers/scripts/delegate.sh initialises .retries file" \
  || fail "helpers/scripts/delegate.sh missing .retries initialisation (bug #3)"

# Regression: shared workflow must cancel the watchdog on normal completion.
# Bug #12 — watchdog kept sleeping after completion, risking PID reuse.
grep -qi 'cancel the watchdog' "$WORKFLOW" \
  && pass "shared/workflow.md cancels watchdog on completion (bug #12 fix)" \
  || fail "shared/workflow.md missing watchdog cancellation on completion (regression of bug #12)"

# Sanity: every skill that defines WORK_DIR must actually use it. Catches the
# class of bug #1 generally (defined-but-unused). A runtime may use it
# indirectly via an intermediate variable (mimo: MIMO_DIR_FLAG="--dir $WORK_DIR",
# codex: _CODEX_WORK_DIR="$WORK_DIR"), so we count occurrences — if WORK_DIR
# appears only once (the assignment), it is never consumed.
for skill in "${SKILLS[@]}"; do
  F="$PROJECT_ROOT/skills/$skill/SKILL.md"
  [ -f "$F" ] || continue
  count=$(grep -c 'WORK_DIR' "$F")
  if [ "$count" -le 1 ]; then
    fail "skills/$skill/SKILL.md defines WORK_DIR but never uses it (count=$count)"
  else
    pass "skills/$skill/SKILL.md uses WORK_DIR (count=$count refs)"
  fi
done

# ─── Standalone summary ───────────────────────────────────────────────────────

if [ "${_standalone:-false}" = "true" ]; then
  echo ""
  echo "  $PASS passed, $FAIL failed"
  [ "$FAIL" -gt 0 ] && exit 1 || exit 0
fi
