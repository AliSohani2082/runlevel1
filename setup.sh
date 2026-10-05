#!/usr/bin/env bash
# setup.sh - build an llm-kit Ventoy stick on a workstation with internet.
#
# Steps (PRD "setup.sh - build the stick"): S1 find the stick, S2 detect
# Ventoy, S3 install/update Ventoy, S4 backend, S5 model, S6 platforms,
# S7 download (latest releases; docs/decisions.md D1/D2), S8 stage + verify.
# Contracts: docs/contracts.md. Needs bash 3.2+, curl, lsblk|diskutil,
# sha256sum|shasum, tar, unzip. No jq.
set -u

LLMKIT_VERSION="0.1.0-dev"
LLMKIT_SCHEMA=1
PROG=setup

# shellcheck disable=SC2034 # exit codes from docs/contracts.md §8; not all used yet
E_USAGE=2 E_PRECOND=3 E_INTEGRITY=4 E_ABORT=5 E_NETWORK=6 E_RESOURCE=7

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
# die WHAT STATE NEXT [CODE] - the readable-failure format (contracts §8).
die() {
  printf '%s: error: %s\n' "$PROG" "$1" >&2
  printf '%s:   state: %s\n' "$PROG" "${2:-nothing was changed}" >&2
  printf '%s:   next:  %s\n' "$PROG" "${3:-run with --help}" >&2
  exit "${4:-1}"
}

usage() {
  cat <<'EOF'
Usage: setup.sh [options]

Build (or update in place) an llm-kit Ventoy USB stick.

Options:
  -h, --help        show this help
      --version     print the llm-kit version
EOF
}

main() {
  while [ $# -gt 0 ]; do
    case $1 in
      -h | --help) usage; exit 0 ;;
      --version) printf '%s (manifest schema %s)\n' "$LLMKIT_VERSION" "$LLMKIT_SCHEMA"; exit 0 ;;
      *) die "unknown option: $1" "nothing was changed" "run setup.sh --help" "$E_USAGE" ;;
    esac
  done
  die "setup.sh is not implemented yet (milestone M3)" "nothing was changed" \
    "see docs/PRD.md milestones" "$E_PRECOND"
}

main "$@"
