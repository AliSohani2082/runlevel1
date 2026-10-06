#!/usr/bin/env bash
# Minimal test runner. Bash 3.2 compatible so host-side tests can run in the
# bash:3.2 container (see `make test-bash32`).
#
# A test file is any tests/**/*_test.sh (up to three levels deep). It defines
# functions named test_*; optional setup/teardown run around each test. Each
# test runs in its own subshell with a fresh $TEST_TMP directory. Exit 0 =
# pass, 77 = skip (use `skip`), anything else = fail.
#
# Usage: tests/run.sh [-k PATTERN] [-v] [FILE...]
set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
export REPO_ROOT
export LLMKIT_DEV_CACHE="${LLMKIT_DEV_CACHE:-$HOME/.cache/llm-kit-dev}"

pattern=""
verbose=0
files=()
while [ $# -gt 0 ]; do
  case $1 in
    -k) pattern=${2:-}; shift 2 ;;
    -v) verbose=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    /*) files+=("$1"); shift ;;
    *) files+=("$PWD/$1"); shift ;;
  esac
done

if [ ${#files[@]} -eq 0 ]; then
  shopt -s nullglob
  files=("$REPO_ROOT"/tests/*_test.sh "$REPO_ROOT"/tests/*/*_test.sh "$REPO_ROOT"/tests/*/*/*_test.sh)
  shopt -u nullglob
fi

pass=0 fail=0 skipped=0
failed_names=()
log=$(mktemp "${TMPDIR:-/tmp}/llmkit-test-log.XXXXXX")
trap 'rm -f "$log"' EXIT

for file in "${files[@]}"; do
  rel=${file#"$REPO_ROOT"/}
  # List test functions defined by this file (in a throwaway subshell).
  tests=$(
    # shellcheck disable=SC1090
    . "$REPO_ROOT/tests/lib/assert.sh" && . "$file" >/dev/null 2>&1
    declare -F | while read -r _ _ name; do
      case $name in (test_*) printf '%s\n' "$name" ;; esac
    done
  )
  for t in $tests; do
    if [ -n "$pattern" ]; then
      case "$rel::$t" in *"$pattern"*) ;; *) continue ;; esac
    fi
    (
      TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/llmkit-test.XXXXXX") || exit 1
      export TEST_TMP
      cleanup() {
        if declare -F teardown >/dev/null; then teardown || true; fi
        if [ "${KEEP_TMP:-0}" = 1 ]; then echo "  kept: $TEST_TMP"; else rm -rf "$TEST_TMP"; fi
      }
      trap cleanup EXIT
      cd "$TEST_TMP" || exit 1
      # shellcheck disable=SC1090
      . "$REPO_ROOT/tests/lib/assert.sh"
      # shellcheck disable=SC1090
      . "$file"
      if declare -F setup >/dev/null; then setup; fi
      "$t"
    ) >"$log" 2>&1
    rc=$?
    case $rc in
      0) pass=$((pass + 1)); echo "PASS  $rel::$t"; [ $verbose = 1 ] && sed 's/^/      /' "$log" ;;
      77) skipped=$((skipped + 1)); echo "SKIP  $rel::$t ($(tail -n 1 "$log"))" ;;
      *) fail=$((fail + 1)); failed_names+=("$rel::$t"); echo "FAIL  $rel::$t (exit $rc)"; sed 's/^/      /' "$log" ;;
    esac
  done
done

echo
echo "passed: $pass  failed: $fail  skipped: $skipped"
if [ $fail -gt 0 ]; then
  for n in "${failed_names[@]}"; do echo "  failed: $n"; done
  exit 1
fi
exit 0
