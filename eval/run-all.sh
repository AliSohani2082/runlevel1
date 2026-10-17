#!/usr/bin/env bash
# Run eval/run-eval.sh for every candidate in eval/candidates.tsv whose GGUF
# is in the dev cache and that has no eval/results/<id>.tsv yet. One model at
# a time; each case takes the inference lock itself.
#
# Usage: eval/run-all.sh [ID...]   (default: every pending candidate)
# Env:   as for run-eval.sh; FORCE=1 re-runs models that already have results.
set -u

here=$(cd "$(dirname "$0")" && pwd)
DEV_CACHE=${LLMKIT_DEV_CACHE:-$HOME/.cache/llm-kit-dev}

want=" $* "
status=0
while IFS='	' read -r id _repo file _sha size ctx _why; do
  case $id in ('' | '#'*) continue ;; esac
  [ $# -eq 0 ] || case $want in (*" $id "*) ;; (*) continue ;; esac
  gguf=$DEV_CACHE/models/$file
  if [ ! -f "$gguf" ]; then
    echo "skip $id: $file is not in the dev cache (yet)"
    continue
  fi
  if [ "$(wc -c <"$gguf" | tr -d ' ')" != "$size" ]; then
    echo "skip $id: $file has the wrong size"
    continue
  fi
  if [ -f "$here/results/$id.tsv" ] && [ "${FORCE:-0}" != 1 ]; then
    echo "skip $id: results exist"
    continue
  fi
  echo "=== $id (ctx $ctx)"
  "$here/run-eval.sh" --ctx "$ctx" "$id" "$gguf" || status=1
done <"$here/candidates.tsv"
exit $status
