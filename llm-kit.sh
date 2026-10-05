#!/usr/bin/env bash
# llm-kit.sh - install and launch the offline DevOps assistant from an llm-kit
# stick. Runs on the booted host.
#
# Steps (PRD "llm-kit.sh - install on the host"): H1 locate payload + read
# manifest, H2 detect host, H3 choose model, H4 choose destination, H5
# install + verify, H6 launch, H7 --uninstall. Contracts: docs/contracts.md.
# Needs bash 3.2+ and coreutils only: no curl, jq, sed, awk, grep or sudo.
# Stay under ~600 lines (PRD Footprint NFR).
set -u

LLMKIT_VERSION="0.1.0-dev"
LLMKIT_SCHEMA=1
PROG=llm-kit

# shellcheck disable=SC2034 # exit codes from docs/contracts.md §8; not all used yet
E_USAGE=2 E_PRECOND=3 E_INTEGRITY=4 E_ABORT=5 E_RESOURCE=7

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
Usage: llm-kit.sh [options]

Install the agent from this stick into a working directory and start it.

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
      *) die "unknown option: $1" "nothing was changed" "run llm-kit.sh --help" "$E_USAGE" ;;
    esac
  done
  die "llm-kit.sh is not implemented yet (milestone M4)" "nothing was changed" \
    "see docs/PRD.md milestones" "$E_PRECOND"
}

main "$@"
