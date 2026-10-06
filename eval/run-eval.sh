#!/usr/bin/env bash
# M2 model evaluation (PRD milestone M2, risk R1): run the 20-case DevOps
# tool-calling suite (eval/cases.sh) against one GGUF, exactly as llm-kit.sh
# will run it: llama-server in router mode with the contracts §7 command line,
# zot driven through its llama.cpp provider with a ZOT_HOME rendered from
# config/. Records per case whether the model made native tool calls and
# whether the task was really done, plus prompt/generation tokens per second.
#
# Usage: eval/run-eval.sh [options] MODEL_ID GGUF
#   --ctx N           context size (-c and models.json); default 16384
#   --cases "A B"     run only these cases (default: all 20)
#   --label NAME      result name (default: MODEL_ID); use it for variants
#   --server-arg ARG  extra llama-server argument (repeatable),
#                     e.g. --server-arg --reasoning --server-arg off
#   --zot-arg ARG     extra zot argument (repeatable)
#   --port N          router port (default 18080, M2's range)
#   --results DIR     where <label>.tsv and runs.tsv go (default eval/results)
#   --no-results      do not write to the results directory
# Env: LLMKIT_DEV_CACHE (~/.cache/llm-kit-dev), EVAL_BIN (dir with
#      llama-server + libs and zot; default $LLMKIT_DEV_CACHE/bin/linux-x86_64),
#      EVAL_CASE_TIMEOUT (seconds per case, 600), EVAL_MAX_STEPS (8)
#
# Isolation: everything runs inside bubblewrap with no network, a private
# PID namespace (nothing outlives the run), and a read-only view of the
# whole machine except the run's work directory. zot's json mode runs tool
# calls without asking, so the model's bash commands must not reach real
# files. Each case holds the shared inference lock while it computes.
set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
# shellcheck source=cases.sh
. "$here/cases.sh"

DEV_CACHE=${LLMKIT_DEV_CACHE:-$HOME/.cache/llm-kit-dev}
LOCK=$DEV_CACHE/locks/inference.lock

say() { printf '[%s] %s\n' "$(date +%T)" "$*" >&2; }
die() { printf 'run-eval: error: %s\n' "$*" >&2; exit 1; }
now_ms() { date +%s%3N; }

# ---------------------------------------------------------------------------
# Inside the sandbox
# ---------------------------------------------------------------------------

inside() {
  local work=$EV_WORK
  local bin=$EV_BIN port=$EV_PORT id=$EV_MODEL_ID ctx=$EV_CTX
  local run=$work/run ws=$work/ws
  export HOME=$work/home ZOT_HOME=$work/zot-home
  unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy
  mkdir -p "$HOME" "$run" "$work/cases"

  exec 9<"$LOCK" || die "cannot open the inference lock $LOCK"
  lock() {
    flock -n 9 || { say "waiting for the inference lock"; flock 9; }
  }
  unlock() { flock -u 9; }

  local key
  key=$(od -An -tx1 -N16 /dev/urandom)
  key=${key//[!0-9a-f]/}
  export LLAMA_ARG_API_KEY=$key LLAMA_API_KEY=$key

  "$bin/llama-server" --version >"$run/llama-version.txt" 2>&1 || die "llama-server --version failed: $(cat "$run/llama-version.txt")"
  "$bin/zot" --version </dev/null >"$run/zot-version.txt" 2>&1

  # contracts §7, plus any experiment arguments
  local -a sargs
  sargs=(--host 127.0.0.1 --port "$port" --models-dir "$work/models"
    --models-max 1 --parallel 1 --jinja -c "$ctx")
  [ -n "$EV_SERVER_ARGS" ] && eval "sargs+=($EV_SERVER_ARGS)"
  printf '%s\n' "${sargs[*]}" >"$run/server-args.txt"
  say "start llama-server: ${sargs[*]}"
  "$bin/llama-server" "${sargs[@]}" >"$run/llama-server.log" 2>&1 9<&- &
  local srv=$! i=0
  while [ $i -lt 60 ]; do
    if http "$port" "$key" GET /health && [ "$HTTP_STATUS" = 200 ]; then break; fi
    kill -0 "$srv" 2>/dev/null || break
    sleep 1
    i=$((i + 1))
  done
  [ "${HTTP_STATUS:-}" = 200 ] || { tail -20 "$run/llama-server.log" >&2; die "/health never answered 200"; }

  lock
  local t0 st="" load_s
  t0=$(now_ms)
  http "$port" "$key" POST /models/load "{\"model\":\"$id\"}"
  [ "$HTTP_STATUS" = 200 ] || { unlock; die "POST /models/load returned $HTTP_STATUS: $HTTP_BODY"; }
  i=0
  while [ $i -lt 600 ]; do
    st=$(router_model_status "$port" "$key" "$id")
    case $st in (loaded) break ;; esac
    case $HTTP_BODY in (*'"failed":true'*) break ;; esac
    sleep 1
    i=$((i + 1))
  done
  unlock
  load_s=$((($(now_ms) - t0) / 1000))
  [ "$st" = loaded ] || { tail -30 "$run/llama-server.log" >&2; die "model did not load (status '$st')"; }
  say "model $id loaded in ${load_s}s"

  local -a zargs
  zargs=(--json --no-session --max-steps "$EV_MAX_STEPS")
  [ -n "$EV_ZOT_ARGS" ] && eval "zargs+=($EV_ZOT_ARGS)"

  local c n=0 total_t0 cdir prompt rc secs offs=""
  total_t0=$(now_ms)
  : >"$work/cases.tsv"
  for c in $EV_CASES; do
    n=$((n + 1))
    cdir=$work/cases/$(printf '%02d' $n)-$c
    mkdir -p "$cdir"
    # Same workspace path for every case, so zot's system prompt (which
    # names the cwd) stays identical and the server can reuse its prefix.
    rm -rf "$ws" && mkdir -p "$ws" && (cd "$ws" && eval_fixture) || die "fixture failed for $c"
    # Fresh ZOT_HOME per case, as llm-kit.sh renders it per launch: a model
    # can overwrite it (the 0.5B smoke model wrote its answer into AGENTS.md).
    rm -rf "$ZOT_HOME" && render_zot_home "$EV_REPO/config" "$ZOT_HOME" "$id" "$ctx" "http://127.0.0.1:$port" ||
      die "cannot render ZOT_HOME"
    prompt=$(eval_prompt "$c")
    printf '%s\n' "$prompt" >"$cdir/prompt.txt"
    lock
    offs="$offs $(wc -c <"$run/llama-server.log")"
    t0=$(now_ms)
    (cd "$ws" && timeout -k 10 "$EV_CASE_TIMEOUT" "$bin/zot" "${zargs[@]}" "$prompt") \
      </dev/null >"$cdir/events.jsonl" 2>"$cdir/zot-stderr.txt" 9<&-
    rc=$?
    secs=$((($(now_ms) - t0) / 1000))
    unlock

    local calls errors steps textcall reasoning answer note pass
    calls=$(ev_tool_calls "$cdir/events.jsonl" | tr '\n' ',')
    calls=${calls%,}
    errors=$(ev_tool_errors "$cdir/events.jsonl")
    steps=$(ev_count "$cdir/events.jsonl" turn_start)
    textcall=$(ev_text_calls "$cdir/events.jsonl")
    reasoning=$(ev_reasoning_tokens "$cdir/events.jsonl")
    answer=$(ev_final_text "$cdir/events.jsonl")
    printf '%s\n' "$answer" >"$cdir/answer.txt"
    note=$(cd "$ws" && ANSWER=$answer "check_$c" 2>&1)
    if [ $? -eq 0 ] && [ -n "$calls" ]; then
      pass=1 note=ok
    else
      pass=0
      [ -n "$calls" ] || note="no native tool call; $note"
      [ $rc -eq 124 ] && note="timed out after ${EV_CASE_TIMEOUT}s; $note"
    fi
    (cd "$work" && tar -czf "$cdir/ws.tar.gz" ws 2>/dev/null)
    note=$(printf '%s' "$note" | tr '\t\n' '  ' | cut -c1-200)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$c" "$(eval_kind "$c")" "$pass" \
      "${calls:--}" "$errors" "$textcall" "$steps" "$secs" "$reasoning" "$rc" "$note" >>"$work/cases.tsv"
    say "$(printf '%2d %-16s pass=%s calls=%s errors=%s steps=%s %ss  %s' \
      $n "$c" "$pass" "${calls:--}" "$errors" "$steps" "$secs" "$note")"
  done
  local total_s=$((($(now_ms) - total_t0) / 1000))

  kill "$srv" 2>/dev/null
  i=0
  while kill -0 "$srv" 2>/dev/null && [ $i -lt 40 ]; do sleep 0.5; i=$((i + 1)); done
  offs="$offs $(wc -c <"$run/llama-server.log")"

  # Per-case token counts from the server log, now that it is complete.
  local -a off
  # shellcheck disable=SC2206 # word splitting of numbers is intended
  off=($offs)
  local row t k=0 sum_pt=0 sum_pm=0 sum_gt=0 sum_gm=0
  printf 'case\tkind\tpass\ttool_calls\ttool_errors\ttext_call\tsteps\tsecs\tprompt_tok\tprompt_tps\tgen_tok\tgen_tps\treasoning_tok\tzot_exit\tnote\n' >"$work/results.tsv"
  while IFS= read -r row; do
    # shellcheck disable=SC2046 # four numbers, split on purpose
    set -- $(log_timings "$run/llama-server.log" "${off[$k]}" "${off[$((k + 1))]}")
    sum_pt=$((sum_pt + $1)) sum_pm=$((sum_pm + $2)) sum_gt=$((sum_gt + $3)) sum_gm=$((sum_gm + $4))
    t=$(printf '%s\t%s\t%s\t%s' "$1" "$(tok_per_s "$1" "$2")" "$3" "$(tok_per_s "$3" "$4")")
    # Insert the timing columns after "secs" (column 8).
    printf '%s\n' "$row" | awk -F'\t' -v OFS='\t' -v t="$t" '{ print $1,$2,$3,$4,$5,$6,$7,$8,t,$9,$10,$11 }' >>"$work/results.tsv"
    k=$((k + 1))
  done <"$work/cases.tsv"

  local passed tool_cases text_cases tool_errors first median v build zv
  passed=$(awk -F'\t' 'NR > 1 && $3 == 1' "$work/results.tsv" | wc -l | tr -d ' ')
  tool_cases=$(awk -F'\t' 'NR > 1 && $4 != "-"' "$work/results.tsv" | wc -l | tr -d ' ')
  text_cases=$(awk -F'\t' 'NR > 1 && $6 == 1' "$work/results.tsv" | wc -l | tr -d ' ')
  tool_errors=$(awk -F'\t' 'NR > 1 { s += $5 } END { print s + 0 }' "$work/results.tsv")
  first=$(awk -F'\t' 'NR == 2 { print $8 }' "$work/results.tsv")
  median=$(awk -F'\t' 'NR > 1 { print $8 }' "$work/results.tsv" | sort -n | awk '{ a[NR] = $1 } END { print (NR ? a[int((NR + 1) / 2)] : 0) }')
  v=$(verdict "$n" "$tool_cases" "$passed")
  build=$(sed -n 's/.*(build \([0-9]*\).*/b\1/p' "$run/llama-version.txt" | head -n 1)
  zv=$(sed -n 's/^zot v\{0,1\}\([0-9][0-9.]*\).*$/v\1/p' "$run/zot-version.txt" | head -n 1)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$EVAL_SUITE" "$EV_LABEL" "$id" "$EV_GGUF_NAME" "$ctx" "${EV_SERVER_ARGS:--}" \
    "${build:-?}" "${zv:-?}" "$n" "$tool_cases" "$passed" "$text_cases" "$tool_errors" \
    "$(tok_per_s "$sum_pt" "$sum_pm")" "$(tok_per_s "$sum_gt" "$sum_gm")" "$load_s" "${first:-0}" "${median:-0}" "$total_s" "$v" \
    >"$work/summary.tsv"
  say "done: $passed/$n passed, native tool calls in $tool_cases/$n cases, text-only calls in $text_cases, prompt $(tok_per_s "$sum_pt" "$sum_pm") tok/s, generation $(tok_per_s "$sum_gt" "$sum_gm") tok/s -> $v"
}

if [ "${1:-}" = __inside ]; then
  inside
  exit $?
fi

# ---------------------------------------------------------------------------
# Outside: parse arguments, prepare the work dir, enter the sandbox
# ---------------------------------------------------------------------------

ctx=16384 cases=$EVAL_CASES label="" port=18080 results=$here/results write_results=1
server_args="" zot_args=""
while [ $# -gt 0 ]; do
  case $1 in
    --ctx) ctx=${2:?}; shift 2 ;;
    --cases) cases=${2:?}; shift 2 ;;
    --label) label=${2:?}; shift 2 ;;
    --server-arg) server_args="$server_args $(printf '%q' "${2:?}")"; shift 2 ;;
    --zot-arg) zot_args="$zot_args $(printf '%q' "${2:?}")"; shift 2 ;;
    --port) port=${2:?}; shift 2 ;;
    --results) results=${2:?}; shift 2 ;;
    --no-results) write_results=0; shift ;;
    -h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) break ;;
  esac
done
[ $# -eq 2 ] || die "usage: run-eval.sh [options] MODEL_ID GGUF (see --help)"
model_id=$1 gguf=$2
label=${label:-$model_id}
[ -f "$gguf" ] || die "no such GGUF: $gguf"
for c in $cases; do eval_prompt "$c" >/dev/null || die "unknown case: $c"; done
bin=${EVAL_BIN:-$DEV_CACHE/bin/linux-x86_64}
[ -x "$bin/llama-server" ] && [ -x "$bin/zot" ] || die "need llama-server and zot in $bin"
command -v bwrap >/dev/null || die "bwrap (bubblewrap) is required for the sandbox"
[ -f "$LOCK" ] || die "missing inference lock file $LOCK"

mkdir -p "$DEV_CACHE/work/m2"
work=$(mktemp -d "$DEV_CACHE/work/m2/$label.$(date +%m%d-%H%M).XXXX") || die "mktemp failed"
mkdir -p "$work/models"
# Hardlink (same filesystem as the dev cache); the router names it by stem.
ln "$gguf" "$work/models/$model_id.gguf" 2>/dev/null || cp "$gguf" "$work/models/$model_id.gguf" || die "cannot stage the GGUF"
say "work dir: $work"

sandbox=(bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp
  --bind "$work" "$work" --unshare-net --unshare-pid --die-with-parent --new-session)
[ -d /run/media ] && sandbox+=(--tmpfs /run/media)

EV_WORK=$work EV_BIN=$bin EV_PORT=$port EV_MODEL_ID=$model_id EV_CTX=$ctx \
  EV_CASES=$cases EV_LABEL=$label EV_SERVER_ARGS=$server_args EV_ZOT_ARGS=$zot_args \
  EV_GGUF_NAME=$(basename "$gguf") EV_REPO=$repo \
  EV_CASE_TIMEOUT=${EVAL_CASE_TIMEOUT:-600} EV_MAX_STEPS=${EVAL_MAX_STEPS:-8} \
  "${sandbox[@]}" bash "$here/run-eval.sh" __inside
rc=$?
rm -rf "$work/models"
[ $rc -eq 0 ] && [ -f "$work/summary.tsv" ] || die "run failed (exit $rc); logs in $work/run"

if [ $write_results = 1 ]; then
  mkdir -p "$results"
  cp "$work/results.tsv" "$results/$label.tsv"
  [ -f "$results/runs.tsv" ] ||
    printf 'date\tsuite\tlabel\tmodel\tgguf\tctx\tserver_args\tllama\tzot\tcases\ttool_cases\tpassed\ttext_call_cases\ttool_errors\tprompt_tps\tgen_tps\tload_s\tfirst_case_s\tmedian_case_s\ttotal_s\tverdict\n' >"$results/runs.tsv"
  cat "$work/summary.tsv" >>"$results/runs.tsv"
  say "results: $results/$label.tsv, $results/runs.tsv"
fi
say "logs and per-case transcripts: $work"
