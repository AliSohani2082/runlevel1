#!/usr/bin/env bash
# M1 spike (PRD milestone M1, risks R3/R4): with the network cut, start
# llama-server in router mode against a --models-dir that already holds a
# GGUF, load the model through the router API, and have zot complete one tool
# call against it. Dev tool; it prototypes the techniques llm-kit.sh needs
# (HTTP over bash /dev/tcp, ZOT_HOME rendered from config/ templates).
#
# Usage: spike/m1-router-offline.sh BIN_DIR MODEL_GGUF [MODEL_ID]
#   BIN_DIR     dir with llama-server (+ libs, symlink-free) and zot
#   MODEL_GGUF  a GGUF file; it is hardlinked/copied as <MODEL_ID>.gguf
# Env: PORT (8080), CTX (8192), PROMPT, WORK (default: mktemp), KEEP=1,
#      SERVER_ARGS (extra llama-server args, e.g. "--chat-template chatml")
#
# The script re-executes itself inside `unshare -rn` (new user + network
# namespace: only a loopback interface, no route anywhere).
set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
PORT=${PORT:-8080}
CTX=${CTX:-8192}
PROMPT=${PROMPT:-Create a file named hello.txt in the current directory containing exactly the text: hello from llm-kit}

step() { printf '[%s] %s\n' "$(date +%T)" "$*"; }
ok() { printf '[%s]   PASS %s\n' "$(date +%T)" "$*"; }
bad() { printf '[%s]   FAIL %s\n' "$(date +%T)" "$*"; FAILED=1; }
FAILED=0

# http METHOD PATH [BODY] -> sets HTTP_STATUS and HTTP_BODY. HTTP/1.0 so the
# server never answers with chunked encoding. bash 3.2 compatible.
http() {
  local method=$1 path=$2 body=${3:-} line
  HTTP_STATUS="" HTTP_BODY=""
  # The redirection error must be silenced on an enclosing group: a 2>/dev/null
  # on the exec itself is applied after 3<> has already failed and printed.
  { exec 3<>"/dev/tcp/127.0.0.1/$PORT"; } 2>/dev/null || return 1
  printf '%s %s HTTP/1.0\r\nHost: 127.0.0.1\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' \
    "$method" "$path" "$API_KEY" "${#body}" "$body" >&3
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

# model_status ID -> prints the router status ("unloaded", "loading", "loaded", ...)
model_status() {
  local rest
  http GET /models || return 1
  case $HTTP_BODY in *"\"id\":\"$1\""*) ;; *) return 1 ;; esac
  rest=${HTTP_BODY#*\"id\":\"$1\"}
  rest=${rest#*\"status\":\{\"value\":\"}
  printf '%s\n' "${rest%%\"*}"
}

render() { # TEMPLATE DEST - replace @VARS@ from the environment of this script
  local s
  s=$(cat "$1")
  s=${s//@PROVIDER@/llama.cpp}
  s=${s//@MODEL_ID@/$MODEL_ID}
  s=${s//@MODEL_NAME@/$MODEL_ID (local)}
  s=${s//@CTX_SIZE@/$CTX}
  s=${s//@MAX_TOKENS@/2048}
  s=${s//@LLAMA_URL@/http://127.0.0.1:$PORT}
  printf '%s\n' "$s" >"$2"
}

inside() {
  BIN=$1 MODELS=$2 MODEL_ID=$3 WORK=$4
  export HOME="$WORK/home" ZOT_HOME="$WORK/zot-home"
  unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
  mkdir -p "$HOME" "$ZOT_HOME" "$WORK/project" "$WORK/run"

  step "network: bring up loopback only, confirm nothing else is reachable"
  ip link set lo up 2>/dev/null || bad "ip link set lo up"
  if (exec 3<>/dev/tcp/1.1.1.1/443) 2>/dev/null; then bad "outbound TCP works (network not cut)"; else ok "no outbound TCP"; fi
  if getent hosts huggingface.co >/dev/null 2>&1; then bad "DNS resolves"; else ok "no DNS"; fi

  # Per-session key (CORS on the router allows any origin; a key stops web
  # pages in a local browser from driving it). Passed via the environment so
  # it does not show up in `ps`. Only /health stays public.
  API_KEY=$(od -An -tx1 -N16 /dev/urandom)
  API_KEY=${API_KEY//[!0-9a-f]/}
  export LLAMA_ARG_API_KEY=$API_KEY LLAMA_API_KEY=$API_KEY

  step "start llama-server in router mode (no -m), models-dir=$MODELS"
  local t0=$SECONDS
  "$BIN/llama-server" --host 127.0.0.1 --port "$PORT" --models-dir "$MODELS" \
    --models-max 1 -c "$CTX" --parallel 1 --jinja ${SERVER_ARGS:-} >"$WORK/run/llama-server.log" 2>&1 &
  local srv=$!
  echo "$srv" >"$WORK/run/llama-server.pid"
  local i=0
  while [ $i -lt 60 ]; do
    if http GET /health && [ "$HTTP_STATUS" = 200 ]; then break; fi
    kill -0 "$srv" 2>/dev/null || break
    sleep 1; i=$((i + 1))
  done
  if [ "$HTTP_STATUS" = 200 ]; then ok "/health 200 after $((SECONDS - t0))s"; else bad "/health never became 200"; tail -20 "$WORK/run/llama-server.log"; return 1; fi

  step "router lists the models-dir entry by file stem (D7)"
  local st
  st=$(model_status "$MODEL_ID") && ok "model '$MODEL_ID' listed, status=$st" || { bad "model '$MODEL_ID' not in /models"; echo "$HTTP_BODY" | head -c 2000; echo; }

  step "load through the router API: POST /models/load"
  t0=$SECONDS
  http POST /models/load "{\"model\":\"$MODEL_ID\"}"
  [ "$HTTP_STATUS" = 200 ] && ok "load accepted: $HTTP_BODY" || bad "load returned $HTTP_STATUS: $HTTP_BODY"
  i=0
  while [ $i -lt 300 ]; do
    st=$(model_status "$MODEL_ID")
    case $st in loaded | sleeping) break ;; esac
    case $HTTP_BODY in *'"failed":true'*) break ;; esac
    sleep 1; i=$((i + 1))
  done
  [ "$st" = loaded ] && ok "status=loaded after $((SECONDS - t0))s" || { bad "status=$st"; tail -30 "$WORK/run/llama-server.log"; }
  local children
  # Children may be forked from any router thread: read every task's list.
  children=$(cat /proc/"$srv"/task/*/children 2>/dev/null)
  step "router child processes: ${children:-none}"

  step "unauthenticated management calls are refused"
  local saved=$API_KEY
  API_KEY=wrong
  http GET /models
  [ "$HTTP_STATUS" = 401 ] && ok "GET /models without the key -> 401" || bad "GET /models without the key -> $HTTP_STATUS"
  API_KEY=$saved

  step "ZOT_HOME from config/ templates; zot --list-models knows the model"
  render "$repo/config/zot-config.json" "$ZOT_HOME/config.json"
  render "$repo/config/zot-auth.json" "$ZOT_HOME/auth.json"; chmod 600 "$ZOT_HOME/auth.json"
  render "$repo/config/models.json" "$ZOT_HOME/models.json"
  cp "$repo/config/AGENTS.md" "$ZOT_HOME/AGENTS.md"
  # --list-models does not query the router; the model is known through
  # models.json (source "user") with our context size.
  "$BIN/zot" --list-models </dev/null >"$WORK/run/zot-list-models.txt" 2>&1
  local row="" l
  while IFS= read -r l; do
    case $l in "llama.cpp "*" $MODEL_ID "*) row=$l ;; esac
  done <"$WORK/run/zot-list-models.txt"
  case $row in
    *" user "*) ok "zot lists llama.cpp/$MODEL_ID from models.json: $row" ;;
    *) bad "zot --list-models has no llama.cpp/$MODEL_ID user row (see run/zot-list-models.txt)" ;;
  esac

  step "zot (config only, no flags) completes one tool call, offline"
  t0=$SECONDS
  # stdin must not be an open pipe: print/json modes read piped stdin to EOF.
  (cd "$WORK/project" && "$BIN/zot" --json --no-session --max-steps 6 "$PROMPT") \
    </dev/null >"$WORK/run/zot-events.jsonl" 2>"$WORK/run/zot-stderr.txt"
  local zrc=$?
  step "zot exit=$zrc after $((SECONDS - t0))s; events: $(wc -l <"$WORK/run/zot-events.jsonl")"
  # A real tool call is a tool_use_start event. A tool name inside assistant
  # text (e.g. a JSON code block the model printed instead of calling the
  # tool) does not count: the harness never executes it.
  local ev calls=""
  while IFS= read -r ev; do
    case $ev in *'"type":"tool_use_start"'*)
      ev=${ev#*\"name\":\"}
      calls="$calls ${ev%%\"*}" ;;
    esac
  done <"$WORK/run/zot-events.jsonl"
  if [ -n "$calls" ]; then ok "native tool call(s):$calls"; else bad "no native tool call (tool_use_start) in the event stream"; fi
  if [ -f "$WORK/project/hello.txt" ]; then
    ok "hello.txt written: $(head -c 200 "$WORK/project/hello.txt")"
  else
    bad "hello.txt not created"
  fi

  step "stop the server we started; its children must exit too"
  kill "$srv" 2>/dev/null
  i=0
  while kill -0 "$srv" 2>/dev/null && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
  kill -0 "$srv" 2>/dev/null && bad "router still running" || ok "router exited"
  local c left=""
  for c in $children; do kill -0 "$c" 2>/dev/null && left="$left $c"; done
  [ -z "$left" ] && ok "no router children left" || bad "children still running:$left"
  return 0
}

if [ "${1:-}" = __inside ]; then
  shift
  inside "$@"
  exit $FAILED
fi

[ $# -ge 2 ] || { sed -n '2,16p' "$0"; exit 2; }
BIN_DIR=$(cd "$1" && pwd) GGUF=$2
MODEL_ID=${3:-$(basename "$GGUF" .gguf)}
# Default work dir on disk next to the dev cache (not tmpfs): GGUFs are
# hardlinked in, which needs the same filesystem.
dev_cache=${LLMKIT_DEV_CACHE:-$HOME/.cache/llm-kit-dev}
mkdir -p "$dev_cache/work"
WORK=${WORK:-$(mktemp -d "$dev_cache/work/m1.XXXXXX")}
mkdir -p "$WORK/models"
ln -f "$GGUF" "$WORK/models/$MODEL_ID.gguf" 2>/dev/null || cp "$GGUF" "$WORK/models/$MODEL_ID.gguf"
step "work dir: $WORK"
unshare -rn bash "$0" __inside "$BIN_DIR" "$WORK/models" "$MODEL_ID" "$WORK"
rc=$?
step "logs: $WORK/run"
[ "${KEEP:-0}" = 1 ] || [ $rc -ne 0 ] || rm -rf "$WORK/models"
exit $rc
