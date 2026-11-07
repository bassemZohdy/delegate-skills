#!/usr/bin/env python3
"""Check installed agent CLIs against the flags delegate.sh relies on.

Reads .github/upstream-sources.yml, runs each runtime's help command(s) and
asserts that every required flag (any one of its alternatives) is present.
Prints a Markdown report suitable for an issue body.

Exit codes: 0 = all checked runtimes satisfy the contract
            1 = drift found (or a help command failed / a required CLI missing)
            2 = usage / manifest error

Usage:
  python tests/check-cli-contract.py                    # check whatever is installed
  python tests/check-cli-contract.py --only codex,pi    # restrict to some runtimes
  python tests/check-cli-contract.py --require-installed  # missing binary = failure
"""
import argparse
import os
import re
import shutil
import subprocess
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    print("ERROR: PyYAML is required (python -m pip install -r tests/requirements.txt)", file=sys.stderr)
    sys.exit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def flag_present(flag, text):
    # Whole-token match: `--file` must not match `--file-format`.
    return re.search(r"(?<![\w-])" + re.escape(flag) + r"(?![\w-])", text) is not None


def run_help(cmd):
    exe = shutil.which(cmd[0])
    if not exe:
        return None, "not installed"
    try:
        proc = subprocess.run([exe] + cmd[1:], capture_output=True, text=True,
                              encoding="utf-8", errors="replace", timeout=90,
                              stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return "", "help command timed out"
    out = ANSI.sub("", (proc.stdout or "") + "\n" + (proc.stderr or ""))
    # A help command that fails AND mentions no flag at all is a broken
    # install (e.g. npm postinstall skipped), not upstream drift.
    if proc.returncode != 0 and "--" not in out:
        first = next((l.strip() for l in out.splitlines() if l.strip()), "no output")
        return out, f"help command failed (exit {proc.returncode}): {first}"
    return out, None


def version_of(binary):
    exe = shutil.which(binary)
    if not exe:
        return "-"
    try:
        proc = subprocess.run([exe, "--version"], capture_output=True, text=True,
                              encoding="utf-8", errors="replace", timeout=60,
                              stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return "?"
    text = ANSI.sub("", (proc.stdout or "") + " " + (proc.stderr or ""))
    m = re.search(r"\d+\.\d+(?:\.\d+)?", text)
    return m.group(0) if m else "?"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default=os.path.join(ROOT, ".github", "upstream-sources.yml"))
    ap.add_argument("--only", default="", help="comma-separated runtime names")
    ap.add_argument("--require-installed", action="store_true")
    args = ap.parse_args()

    try:
        with open(args.manifest, encoding="utf-8") as fh:
            manifest = yaml.safe_load(fh)
        runtimes = manifest["runtimes"]
    except (OSError, KeyError, TypeError, yaml.YAMLError) as exc:
        print(f"ERROR: cannot read manifest {args.manifest}: {exc}", file=sys.stderr)
        return 2

    only = [r for r in args.only.split(",") if r]
    unknown = [r for r in only if r not in runtimes]
    if unknown:
        print(f"ERROR: unknown runtime(s): {', '.join(unknown)}", file=sys.stderr)
        return 2

    failed = False
    rows, details = [], []
    for name, spec in runtimes.items():
        if only and name not in only:
            continue
        binary = spec["binary"]
        installed = version_of(binary)
        problems, broken = [], False
        for check in spec.get("help", []):
            cmd = check["cmd"]
            text, err = run_help(cmd)
            if err == "not installed":
                problems = ["not installed"]
                break
            if err:
                broken = True
                problems.append(f"`{' '.join(cmd)}`: {err}")
                continue
            for alternatives in check.get("require", []):
                if not any(flag_present(f, text) for f in alternatives):
                    problems.append(f"`{' '.join(cmd)}` no longer lists {' / '.join('`'+f+'`' for f in alternatives)}")
        if problems == ["not installed"]:
            status = "not installed"
            if args.require_installed:
                failed = True
                status = "**MISSING**"
        elif problems:
            failed = True
            status = "**BROKEN**" if broken else "**DRIFT**"
            details.append((name, problems))
        else:
            status = "ok"
        rows.append(f"| {name} | {installed} | {spec.get('verified', '-')} | {spec.get('latest_seen', '-')} | {status} |")

    print("## Agent CLI contract check\n")
    print("Flags that `helpers/scripts/delegate.sh` passes, checked against each installed CLI's `--help`.\n")
    print("| Runtime | Installed | Verified (AGENTS.md) | Latest seen | Status |")
    print("|---------|-----------|----------------------|-------------|--------|")
    print("\n".join(rows))
    for name, problems in details:
        print(f"\n### {name}\n")
        for p in problems:
            print(f"- {p}")
        srcs = runtimes[name].get("docs", []) + runtimes[name].get("changelog", [])
        if srcs:
            print("\nSources: " + ", ".join(srcs))
    if details:
        print("\nUpdate `helpers/scripts/delegate.sh`, the affected `skills/delegate-to-*/SKILL.md`, "
              "the AGENTS.md CLI table and `.github/upstream-sources.yml`, then run "
              "`bash helpers/scripts/sync-skills.sh`.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
