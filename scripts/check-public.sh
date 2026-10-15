#!/bin/bash
# Leak check before anything goes public. Fails (exit 1) if it finds:
#   • files that must stay local (Claude's notes, memory/, local signing config) being tracked
#   • home-directory paths or private keys in tracked text
#   • your own private strings, listed one regex per line in .git/info/lattice-private-patterns
#     (inside .git → never pushed; e.g. your name, team ID, server addresses)
#   • secrets found by gitleaks (API keys, tokens, passwords) — in files and in history
#
#   scripts/check-public.sh [REV...]   check the tracked files + the history of REV (default HEAD)
#   scripts/check-public.sh --staged   check only what is staged (pre-commit)
# Only the history being published is scanned — local-only branches (e.g. a private archive) are not.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
fail=0
red() { printf '\033[31m%s\033[0m\n' "$*"; }

MODE="${1:-all}"
REVS=("$@"); [[ "$MODE" == "--staged" || ${#REVS[@]} -eq 0 ]] && REVS=(HEAD)
if [[ "$MODE" == "--staged" ]]; then
  FILES=$(git diff --cached --name-only --diff-filter=ACMR)
else
  FILES=$(git ls-files)
fi

# 1. Paths that must never be tracked.
FORBIDDEN='^(memory/|CLAUDE(\.local)?\.md$|\.claude/|scripts/signing\.env$|.*\.p12$|.*\.p8$|.*\.mobileprovision$|.*\.env$)'
bad=$(echo "$FILES" | grep -E "$FORBIDDEN" || true)
if [[ -n "$bad" ]]; then red "✗ private files would go public:"; echo "$bad" | sed 's/^/    /'; fail=1; fi

# 2. Generic leaks in file contents.
GENERIC='/Users/[A-Za-z0-9._-]+/|/home/[A-Za-z0-9._-]+/|BEGIN (RSA|OPENSSH|EC|PGP) PRIVATE KEY|claude-[0-9]+/'
# 3. Personal patterns (local only).
PRIV=.git/info/lattice-private-patterns
for f in $FILES; do
  [[ -f "$f" ]] || continue
  [[ "$f" == "scripts/check-public.sh" ]] && continue          # this file names the patterns
  content() { if [[ "$MODE" == "--staged" ]]; then git show ":$f" 2>/dev/null; else cat "$f"; fi; }
  hits=$(content | grep -nIE "$GENERIC" || true)
  if [[ -s "$PRIV" ]]; then
    hits+=$(content | grep -nIiEf <(grep -v '^\s*#' "$PRIV" | grep -v '^\s*$') || true)
  fi
  if [[ -n "$hits" ]]; then red "✗ $f:"; echo "$hits" | cut -c1-160 | sed 's/^/    /'; fail=1; fi
done

# 4. gitleaks: secrets in the files (and, for a full check, every commit reachable from REVS).
if command -v gitleaks >/dev/null; then
  if [[ "$MODE" == "--staged" ]]; then
    gitleaks git --staged --redact --no-banner -l warn . || fail=1
  else
    gitleaks git --log-opts="${REVS[*]}" --redact --no-banner -l warn . || fail=1
  fi
else
  red "⚠️ gitleaks not installed (brew install gitleaks) — secret scan skipped"
fi

if [[ $fail -ne 0 ]]; then red "Leak check failed — nothing should go public until this is clean."; exit 1; fi
echo "✓ leak check clean"
