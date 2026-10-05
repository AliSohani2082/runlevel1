# shellcheck shell=bash
# Assertion helpers for tests/run.sh. Bash 3.2 compatible.
# Sourced inside each test's subshell; failures exit that subshell.

fail() {
  printf 'assertion failed: %s\n' "$*" >&2
  exit 1
}

# skip REASON - mark the current test as skipped (exit 77).
skip() {
  printf '%s\n' "${*:-skipped}"
  exit 77
}

# require_cmd NAME... - skip unless every command exists.
require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || skip "requires $c"
  done
}

# run CMD... - run a command, capturing combined output in $OUTPUT and the
# exit status in $STATUS. Never fails by itself.
run() {
  OUTPUT=$("$@" 2>&1)
  STATUS=$?
  return 0
}

assert_eq() { # expected actual [msg]
  [ "$1" = "$2" ] || fail "${3:-values differ}: expected [$1], got [$2]"
}

assert_ne() { # unexpected actual [msg]
  [ "$1" != "$2" ] || fail "${3:-values equal}: did not expect [$1]"
}

assert_contains() { # haystack needle [msg]
  case $1 in
    *"$2"*) ;;
    *) fail "${3:-missing substring}: [$2] not found in:
$1" ;;
  esac
}

assert_not_contains() { # haystack needle [msg]
  case $1 in
    *"$2"*) fail "${3:-unexpected substring}: [$2] found in:
$1" ;;
  esac
}

assert_match() { # string regex [msg]
  local re=$2
  [[ $1 =~ $re ]] || fail "${3:-no match}: [$1] !~ /$2/"
}

assert_status() { # expected_status CMD... (sets OUTPUT/STATUS like run)
  local want=$1
  shift
  run "$@"
  [ "$STATUS" = "$want" ] || fail "expected exit $want, got $STATUS from: $*
output:
$OUTPUT"
}

assert_file() { [ -f "$1" ] || fail "expected file: $1"; }
assert_no_file() { [ ! -e "$1" ] || fail "expected no file: $1"; }
assert_dir() { [ -d "$1" ] || fail "expected directory: $1"; }
assert_executable() { [ -x "$1" ] || fail "expected executable: $1"; }
