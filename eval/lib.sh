# shellcheck shell=bash
# Shared helpers for the M2 model evaluation (eval/run-eval.sh) and its tests.
# Dev tooling: jq and awk are allowed here (they are not on live hosts, but
# this never ships). Syntax stays bash-3.2 parseable (`make lint`).

# --- zot event stream (zot --json, one JSON object per line) ----------------
# Lines that are not valid JSON (a run killed mid-write) are skipped.

# ev_tool_calls FILE - names of native tool calls (tool_use_start), one per line.
# A tool name printed inside assistant text is not a tool call (spike-m1 #15).
ev_tool_calls() {
  jq -rR 'fromjson? | select(.type == "tool_use_start") | .name' "$1"
}

# ev_count FILE TYPE - number of events of TYPE.
ev_count() {
  jq -rRn --arg t "$2" '[inputs | fromjson? | select(.type == $t)] | length' "$1"
}

# ev_tool_errors FILE - number of tool results flagged is_error (bad args,
# missing file, failed edit match, ...).
ev_tool_errors() {
  jq -rRn '[inputs | fromjson? | select(.type == "tool_result" and .is_error == true)] | length' "$1"
}

# ev_final_text FILE - text of the last assistant message that has any text.
ev_final_text() {
  jq -rRn '[inputs | fromjson? | select(.type == "assistant_message")
            | [.content[]? | select(.type == "text") | .text] | join("")
            | select(length > 0)] | last // ""' "$1"
}

# ev_all_text FILE - every assistant text block, in order.
ev_all_text() {
  jq -rR 'fromjson? | select(.type == "assistant_message") | .content[]? | select(.type == "text") | .text' "$1"
}

# ev_reasoning_tokens FILE - reasoning tokens reported in usage events (0 when
# the provider reports none).
ev_reasoning_tokens() {
  jq -rRn '[inputs | fromjson? | select(.type == "usage") | (.reasoning // 0)] | add // 0' "$1"
}

# ev_text_calls FILE - 1 if assistant text looks like a tool call the model
# printed instead of emitting it natively (a ```json {"name": "write", ...}
# block, a literal <tool_call> tag), else 0. This is the M1 failure mode.
ev_text_calls() {
  local re='<tool_call>|"name"[[:space:]]*:[[:space:]]*"(read|write|edit|bash|glob)"|"(arguments|parameters)"[[:space:]]*:[[:space:]]*\{'
  if ev_all_text "$1" | grep -Eq "$re"; then echo 1; else echo 0; fi
}

# --- llama-server log -------------------------------------------------------

# log_timings FILE [START_BYTE [END_BYTE]] - sum the slot timing lines in a
# byte range of the router log. Prints:
#   prompt_tokens prompt_ms gen_tokens gen_ms requests
# Children's output is forwarded by the router with a [pid] prefix, e.g.
#   ... print_timing: id  0 | task 0 | prompt eval time =   13506.29 ms /  1552 tokens (...)
#   ... print_timing: id  0 | task 0 |        eval time =    3021.64 ms /    63 tokens (...)
log_timings() {
  local start=${2:-0} end=${3:-}
  local len=""
  [ -n "$end" ] && len=$((end - start))
  {
    if [ -n "$len" ]; then
      tail -c +"$((start + 1))" "$1" | head -c "$len"
    else
      tail -c +"$((start + 1))" "$1"
    fi
  } | awk '
    function grab(s, k,   f) {
      split(s, f, " ")
      ms[k] += f[1]; tok[k] += f[4]
    }
    /print_timing/ && /prompt eval time =/ { split($0, a, "prompt eval time ="); grab(a[2], "p"); n++; next }
    /print_timing/ && /[^t] eval time =/   { split($0, a, " eval time =");      grab(a[2], "g") }
    END { printf "%d %d %d %d %d\n", tok["p"], ms["p"], tok["g"], ms["g"], n }'
}

# tok_per_s TOKENS MS - tokens per second with one decimal, or "-" for no data.
tok_per_s() {
  if [ "${2:-0}" -gt 0 ] 2>/dev/null; then
    awk -v t="$1" -v m="$2" 'BEGIN { printf "%.1f\n", t * 1000 / m }'
  else
    echo -
  fi
}

# --- router HTTP over /dev/tcp (as llm-kit.sh will do it; contracts §7) ------

# http PORT KEY METHOD PATH [BODY] - sets HTTP_STATUS and HTTP_BODY.
# HTTP/1.0 so the server never answers chunked.
# shellcheck disable=SC2034 # HTTP_STATUS is for the caller
http() {
  local port=$1 key=$2 method=$3 path=$4 body=${5:-} line
  HTTP_STATUS="" HTTP_BODY=""
  { exec 3<>"/dev/tcp/127.0.0.1/$port"; } 2>/dev/null || return 1
  printf '%s %s HTTP/1.0\r\nHost: 127.0.0.1\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' \
    "$method" "$path" "$key" "${#body}" "$body" >&3
  IFS= read -r line <&3 || { exec 3<&-; return 1; }
  line=${line#* }
  HTTP_STATUS=${line%% *}
  while IFS= read -r line <&3; do
    line=${line%$'\r'}
    [ -z "$line" ] && break
  done
  while IFS= read -r line <&3 || [ -n "$line" ]; do HTTP_BODY="$HTTP_BODY$line"; done
  exec 3<&-
  return 0
}

# router_model_status PORT KEY ID - prints the router's status.value for ID.
router_model_status() {
  local rest
  http "$1" "$2" GET /models || return 1
  case $HTTP_BODY in *"\"id\":\"$3\""*) ;; *) return 1 ;; esac
  rest=${HTTP_BODY#*\"id\":\""$3"\"}
  rest=${rest#*\"status\":\{\"value\":\"}
  printf '%s\n' "${rest%%\"*}"
}

# --- ZOT_HOME (contracts §7 "Template placeholders") ------------------------

# max_tokens CTX - 4096, or ctx/4 if that is smaller.
max_tokens() {
  local q=$(($1 / 4))
  if [ "$q" -lt 4096 ]; then echo "$q"; else echo 4096; fi
}

# render_template SRC DEST MODEL_ID CTX URL
render_template() {
  local s
  s=$(cat "$1") || return 1
  s=${s//@PROVIDER@/llama.cpp}
  s=${s//@MODEL_ID@/$3}
  s=${s//@MODEL_NAME@/$3 (local)}
  s=${s//@CTX_SIZE@/$4}
  s=${s//@MAX_TOKENS@/$(max_tokens "$4")}
  s=${s//@LLAMA_URL@/$5}
  printf '%s\n' "$s" >"$2"
}

# render_zot_home CONFIG_DIR ZOT_HOME MODEL_ID CTX URL - what llm-kit.sh renders
# on every launch: config.json, auth.json (600), models.json, AGENTS.md.
render_zot_home() {
  local cfg=$1 zh=$2
  mkdir -p "$zh" || return 1
  render_template "$cfg/zot-config.json" "$zh/config.json" "$3" "$4" "$5" &&
    render_template "$cfg/zot-auth.json" "$zh/auth.json" "$3" "$4" "$5" &&
    chmod 600 "$zh/auth.json" &&
    render_template "$cfg/models.json" "$zh/models.json" "$3" "$4" "$5" &&
    cp "$cfg/AGENTS.md" "$zh/AGENTS.md" &&
    rm -f "$zh/models-cache.json"
}

# --- verdict (docs/eval-m2.md "Criteria") -----------------------------------

# verdict CASES TOOL_CASES PASSED - catalog tool_calling value for a run.
#   verified:   native tool calls in >= 90% of cases and >= 75% of cases passed
#   broken:     native tool calls in < 50% of cases, or < 25% of cases passed
#               (calls with nonsense arguments are as useless as no calls)
#   unverified: anything in between (calls tools, but not reliably enough)
verdict() {
  local n=$1 t=$2 p=$3
  [ "$n" -gt 0 ] || { echo unverified; return; }
  if [ $((t * 100)) -ge $((n * 90)) ] && [ $((p * 100)) -ge $((n * 75)) ]; then
    echo verified
  elif [ $((t * 100)) -lt $((n * 50)) ] || [ $((p * 100)) -lt $((n * 25)) ]; then
    echo broken
  else
    echo unverified
  fi
}
