#!/usr/bin/env bash
# tests/test-upstream.sh — the upstream-source manifest and the CLI contract
# checker (.github/upstream-sources.yml, tests/check-cli-contract.py).
#
# Never touches the network or a real agent CLI: the checker is exercised
# through a temporary manifest whose "help commands" are Python one-liners.
# Can be sourced by run-tests.sh or run standalone.

if ! declare -f pass &>/dev/null; then
  PASS=0; FAIL=0
  pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
  fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
  PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  _standalone=true
fi
if [ -z "${PYTHON:-}" ]; then
  if command -v python3 &>/dev/null; then PYTHON=python3; else PYTHON=python; fi
fi

MANIFEST="$PROJECT_ROOT/.github/upstream-sources.yml"
CHECKER="$PROJECT_ROOT/tests/check-cli-contract.py"

# ─── Manifest shape and agreement with the rest of the repo ─────────────────
# Prints PASS/FAIL lines; bash turns them into pass/fail calls.
_manifest_report=$("$PYTHON" - "$MANIFEST" "$PROJECT_ROOT" <<'PYEOF' 2>&1
import re, sys, yaml
manifest, root = sys.argv[1], sys.argv[2]
expected = ["opencode", "pi", "mimo", "hermes", "kimi", "codex", "agy"]
try:
    m = yaml.safe_load(open(manifest, encoding="utf-8"))
except Exception as exc:
    print(f"FAIL upstream-sources.yml does not parse: {exc}"); sys.exit()
print("PASS upstream-sources.yml parses")
rts = m.get("runtimes") or {}
print(("PASS" if sorted(rts) == sorted(expected) else "FAIL") +
      f" manifest lists exactly the 7 runtimes (got {sorted(rts)})")
print(("PASS" if m.get("spec", {}).get("docs") else "FAIL") + " manifest has agentskills spec sources")

agents = open(f"{root}/AGENTS.md", encoding="utf-8").read()
line = next((l for l in agents.splitlines() if l.startswith("Last verified against")), "")
launcher = open(f"{root}/helpers/scripts/delegate.sh", encoding="utf-8").read()
for name in expected:
    rt = rts.get(name) or {}
    missing = [k for k in ("binary", "install", "docs", "changelog", "verified", "latest_seen", "help") if not rt.get(k)]
    print(("FAIL" if missing else "PASS") + f" manifest {name}: required keys present" + (f" (missing {missing})" if missing else ""))
    urls = list(rt.get("docs") or []) + list(rt.get("changelog") or [])
    bad = [u for u in urls if not str(u).startswith("https://")]
    print(("FAIL" if bad or not urls else "PASS") + f" manifest {name}: sources are https URLs" + (f" ({bad})" if bad else ""))
    v = str(rt.get("verified", ""))
    ok = bool(v) and re.search(r"(?<![\d.])" + re.escape(v) + r"(?![\d.])", line) is not None
    print(("PASS" if ok else "FAIL") + f" manifest {name}: verified {v} matches the AGENTS.md 'Last verified' line")
    # Every required flag must be one the launcher actually knows about —
    # otherwise the contract checks something we do not depend on.
    for chk in rt.get("help") or []:
        for alts in chk.get("require") or []:
            known = any(re.search(r"(?<![\w-])" + re.escape(f) + r"(?![\w-])", launcher) for f in alts)
            if not known:
                # long-form aliases of short flags the launcher uses
                aliases = {"--model": "-m", "--prompt": "-p", "--continue": "-c", "--query": "-q",
                           "--quiet": "-Q", "--config": "-c", "--cd": "-C", "--sandbox": "-s"}
                known = any(aliases.get(f) and re.search(r"(?<![\w-])" + re.escape(aliases[f]) + r"(?![\w-])", launcher) for f in alts)
            print(("PASS" if known else "FAIL") + f" manifest {name}: required {'/'.join(alts)} is used by delegate.sh")
PYEOF
)
while IFS= read -r _l; do
  case "$_l" in
    PASS\ *) pass "${_l#PASS }" ;;
    FAIL\ *) fail "${_l#FAIL }" ;;
    *) [ -n "$_l" ] && fail "manifest check error: $_l" ;;
  esac
done <<< "$_manifest_report"

# ─── Checker behavior against fake help output ──────────────────────────────
_UP_TMP=$(mktemp -d)
_PY_ABS=$("$PYTHON" -c "import sys; print(sys.executable)")

# $1 = name, $2 = fake help text, $3.. = YAML require entries (flow lists)
_fake_manifest() {
  local name=$1 help=$2; shift 2
  {
    echo "runtimes:"
    echo "  $name:"
    echo "    binary: $name-not-a-real-binary"
    echo "    help:"
    echo "      - cmd: ['$_PY_ABS', '-c', 'print(\"$help\")']"
    echo "        require:"
    for r in "$@"; do echo "          - $r"; done
  } > "$_UP_TMP/m.yml"
}
_run_checker() { "$PYTHON" "$CHECKER" --manifest "$_UP_TMP/m.yml" "$@" > "$_UP_TMP/out.md" 2>&1; echo $?; }

_fake_manifest allflags "usage: x --dir D --file F --model M" "[--dir]" "[--model]"
[ "$(_run_checker)" = 0 ] && grep -q ' ok |$' "$_UP_TMP/out.md" \
  && pass "contract checker: all flags present → exit 0, ok" \
  || fail "contract checker: all flags present should pass ($(cat "$_UP_TMP/out.md"))"

_fake_manifest drift "usage: x --dir D" "[--dir]" "[--continue]"
[ "$(_run_checker)" = 1 ] && grep -q 'DRIFT' "$_UP_TMP/out.md" && grep -q 'no longer lists `--continue`' "$_UP_TMP/out.md" \
  && pass "contract checker: missing flag → exit 1, DRIFT names the flag" \
  || fail "contract checker: missing flag should report DRIFT ($(cat "$_UP_TMP/out.md"))"

_fake_manifest alt "usage: x --auto" "[--auto, --dangerously-skip-permissions]"
[ "$(_run_checker)" = 0 ] \
  && pass "contract checker: any one alternative satisfies a requirement" \
  || fail "contract checker: alternative flags not honored ($(cat "$_UP_TMP/out.md"))"

_fake_manifest token "usage: x --file-format F --dir-mode D" "[--file]"
[ "$(_run_checker)" = 1 ] \
  && pass "contract checker: --file does not match --file-format (whole-token match)" \
  || fail "contract checker: partial flag names must not count"

# binary present but help fails with no flags in its output → BROKEN, not DRIFT
cat > "$_UP_TMP/m.yml" <<EOF
runtimes:
  broken:
    binary: broken-not-a-real-binary
    help:
      - cmd: ['$_PY_ABS', '-c', 'import sys; print("postinstall script was not run"); sys.exit(1)']
        require:
          - [--dir]
EOF
[ "$(_run_checker)" = 1 ] && grep -q 'BROKEN' "$_UP_TMP/out.md" && ! grep -q 'DRIFT' "$_UP_TMP/out.md" \
  && pass "contract checker: failing help with no flags → BROKEN (install problem), not DRIFT" \
  || fail "contract checker: broken install misreported ($(cat "$_UP_TMP/out.md"))"

cat > "$_UP_TMP/m.yml" <<EOF
runtimes:
  absent:
    binary: absent-not-a-real-binary
    help:
      - cmd: [absent-not-a-real-binary, --help]
        require:
          - [--dir]
EOF
[ "$(_run_checker)" = 0 ] && grep -q 'not installed' "$_UP_TMP/out.md" \
  && pass "contract checker: missing CLI is reported, not a failure, by default" \
  || fail "contract checker: missing CLI should not fail by default"
[ "$(_run_checker --require-installed)" = 1 ] && grep -q 'MISSING' "$_UP_TMP/out.md" \
  && pass "contract checker: --require-installed turns a missing CLI into a failure" \
  || fail "contract checker: --require-installed should fail on a missing CLI"
[ "$(_run_checker --only nope)" = 2 ] \
  && pass "contract checker: unknown --only runtime → exit 2" \
  || fail "contract checker: unknown --only runtime should exit 2"

rm -rf "$_UP_TMP"

# ─── CI wiring ──────────────────────────────────────────────────────────────
WF="$PROJECT_ROOT/.github/workflows"
if grep -q 'check-cli-contract.py' "$WF/cli-contract.yml" 2>/dev/null; then
  pass "cli-contract.yml runs the contract checker"
else
  fail "cli-contract.yml missing or does not run tests/check-cli-contract.py"
fi
# The job that runs npm install scripts must not hold a write token.
if "$PYTHON" - "$WF/cli-contract.yml" <<'PYEOF'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
jobs = wf["jobs"]
assert wf.get("permissions") == {}, "top-level permissions must be {}"
assert jobs["check"]["permissions"] == {"contents": "read"}, jobs["check"]["permissions"]
assert jobs["report"]["permissions"] == {"issues": "write"}, jobs["report"]["permissions"]
assert not any("npm" in str(s.get("run", "")) for s in jobs["report"]["steps"]), "report job runs npm"
assert "pull_request" in jobs["report"]["if"], "report job must not run on pull_request"
PYEOF
then
  pass "cli-contract.yml: install job read-only; issue job write-only and no third-party code"
else
  fail "cli-contract.yml permissions split is wrong"
fi
if [ -f "$WF/upstream-watch.md" ] \
   && grep -q '^engine:' "$WF/upstream-watch.md" \
   && grep -q 'create-issue:' "$WF/upstream-watch.md" \
   && grep -q 'untrusted data' "$WF/upstream-watch.md" \
   && ! grep -qE '^\s+(contents|issues): write' "$WF/upstream-watch.md"; then
  pass "upstream-watch.md: agentic workflow is read-only, issues via safe-outputs, fetched content untrusted"
else
  fail "upstream-watch.md missing or not read-only / safe-outputs based"
fi

if [ "${_standalone:-false}" = "true" ]; then
  echo ""
  echo "  $PASS passed, $FAIL failed"
  [ "$FAIL" -gt 0 ] && exit 1 || exit 0
fi
