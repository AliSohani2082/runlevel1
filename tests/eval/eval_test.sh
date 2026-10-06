# shellcheck shell=bash
# Tests for the M2 evaluation harness (eval/): the cases' checks must be
# satisfiable and must not pass on the untouched fixture, and the event/log
# parsers must read zot's and llama-server's real formats. No model runs here.

setup() {
  require_cmd jq awk grep tar
  # shellcheck source=../../eval/lib.sh
  . "$REPO_ROOT/eval/lib.sh"
  # shellcheck source=../../eval/cases.sh
  . "$REPO_ROOT/eval/cases.sh"
}

test_suite_has_twenty_cases_with_prompt_kind_check_and_solution() {
  local c n=0
  for c in $EVAL_CASES; do
    n=$((n + 1))
    assert_ne "" "$(eval_prompt "$c")" "prompt for $c"
    assert_ne "" "$(eval_kind "$c")" "kind for $c"
    declare -F "check_$c" >/dev/null || fail "check_$c is not defined"
    declare -F "solve_$c" >/dev/null || fail "solve_$c is not defined"
  done
  assert_eq 20 "$n" "number of cases"
}

test_no_check_passes_on_the_untouched_fixture() {
  local c out
  for c in $EVAL_CASES; do
    rm -rf ws && mkdir ws && (cd ws && eval_fixture) || fail "fixture for $c"
    if out=$(cd ws && ANSWER="" "check_$c" 2>&1); then
      fail "check_$c passes without doing anything"
    fi
    assert_ne "" "$out" "check_$c must say why it failed"
  done
}

test_every_check_passes_after_its_reference_solution() {
  local c answer out
  for c in $EVAL_CASES; do
    rm -rf ws && mkdir ws && (cd ws && eval_fixture) || fail "fixture for $c"
    answer=$(cd ws && "solve_$c") || fail "solve_$c failed"
    out=$(cd ws && ANSWER=$answer "check_$c" 2>&1) || fail "check_$c rejects the reference solution: $out"
  done
}

test_fixture_facts_match_the_expected_answers() {
  eval_fixture
  assert_eq 60 "$(wc -l <logs/access.log | tr -d ' ')" "access.log lines"
  assert_eq 7 "$(grep -c '" 500 ' logs/access.log)" "500s in access.log"
  assert_eq 7 "$(grep -c '500' logs/access.log)" "no other field contains 500"
  assert_eq 11 "$(grep -c ERROR logs/app-billing.log)"
  assert_eq 5 "$(grep -c ERROR logs/app-auth.log)"
  assert_eq 3 "$(grep -c ERROR logs/app-api.log)"
  assert_eq 0 "$(grep -c ERROR logs/app-web.log)"
  [ -x deploy.sh ] && fail "deploy.sh must start non-executable"
  jq . config/app.json >/dev/null 2>&1 && fail "config/app.json must start broken"
  return 0
}

test_checks_reject_typical_wrong_outcomes() {
  eval_fixture
  ANSWER="postgres is listening on 5432" run check_ss_listener
  assert_eq 1 "$STATUS" "guessing postgres must fail"
  ANSWER="ext4" run check_fstab_var
  assert_eq 1 "$STATUS"
  ANSWER="There were 17 errors" run check_count_500
  assert_eq 1 "$STATUS" "17 is not 7"
  ANSWER="postgres (pid 1104)" run check_oom_victim
  assert_eq 1 "$STATUS" "the process that invoked the OOM killer is not the victim"
  # Adding LOG_LEVEL at the wrong indentation (outside the env list).
  printf '      - name: LOG_LEVEL\n        value: debug\n' >>k8s/deployment.yaml
  run check_k8s_env
  assert_eq 1 "$STATUS"
  assert_contains "$OUTPUT" "not in the container's env list"
  # Replacing the whole crontab loses the existing entries.
  printf '30 3 * * * root /usr/local/bin/backup.sh\n' >etc/crontab
  run check_cron_add
  assert_eq 1 "$STATUS"
}

# A tool call as zot --json reports it (shape taken from the M1 spike run).
write_native_events() {
  cat >"$1" <<'EOF'
{"content":[{"text":"Create hello.txt","type":"text"}],"time":"2026-10-06T02:39:24+03:30","type":"user_message"}
{"step":1,"type":"turn_start"}
{"type":"assistant_start"}
{"id":"abc","name":"write","type":"tool_use_start"}
{"delta":"{\"path\": \"hello.txt\"","id":"abc","type":"tool_use_args"}
{"id":"abc","type":"tool_use_end"}
{"cache_read":0,"input":1552,"output":63,"reasoning":null,"type":"usage"}
{"content":[{"args":{"content":"hi","path":"hello.txt"},"id":"abc","name":"write","type":"tool_call"}],"type":"assistant_message"}
{"stop":"tool_use","type":"turn_end"}
{"content":[{"text":"no such file","type":"text"}],"id":"abc","is_error":true,"type":"tool_result"}
{"step":2,"type":"turn_start"}
{"id":"def","name":"bash","type":"tool_use_start"}
{"content":[{"text":"ok","type":"text"}],"id":"def","is_error":false,"type":"tool_result"}
{"cache_read":1554,"input":93,"output":50,"reasoning":12,"type":"usage"}
{"content":[{"text":"The file ","type":"text"},{"text":"was written.","type":"text"}],"type":"assistant_message"}
{"stop":"end","type":"turn_end"}
{"type":"done"}
EOF
}

test_event_parsers_read_native_tool_calls() {
  write_native_events ev.jsonl
  assert_eq "write
bash" "$(ev_tool_calls ev.jsonl)"
  assert_eq 1 "$(ev_tool_errors ev.jsonl)"
  assert_eq 2 "$(ev_count ev.jsonl turn_start)"
  assert_eq "The file was written." "$(ev_final_text ev.jsonl)"
  assert_eq 12 "$(ev_reasoning_tokens ev.jsonl)"
  assert_eq 0 "$(ev_text_calls ev.jsonl)"
}

test_event_parsers_flag_a_tool_call_printed_as_text() {
  # The M1 failure mode of Qwen2.5-Coder-7B: the call is only text.
  cat >ev.jsonl <<'EOF'
{"step":1,"type":"turn_start"}
{"content":[{"text":"```json\n{\"name\": \"write\", \"arguments\": {\"path\": \"hello.txt\"}}\n```","type":"text"}],"type":"assistant_message"}
{"type":"done"}
EOF
  assert_eq "" "$(ev_tool_calls ev.jsonl)"
  assert_eq 1 "$(ev_text_calls ev.jsonl)"
}

test_event_parsers_skip_a_truncated_last_line() {
  write_native_events ev.jsonl
  printf '{"content":[{"text":"cut of' >>ev.jsonl
  assert_eq 2 "$(ev_tool_calls ev.jsonl | wc -l | tr -d ' ')"
  assert_eq "The file was written." "$(ev_final_text ev.jsonl)"
}

test_log_timings_sums_a_byte_range() {
  printf '%s\n' \
    '[52127] 0.18.729.166 I slot print_timing: id  0 | task 0 | prompt eval time =   13506.29 ms /  1552 tokens (    8.70 ms per token,   114.91 tokens per second)' \
    '[52127] 0.18.729.175 I slot print_timing: id  0 | task 0 |        eval time =    3021.64 ms /    63 tokens (   48.74 ms per token,    20.52 tokens per second)' \
    '[52127] 0.18.729.178 I slot print_timing: id  0 | task 0 |       total time =   16527.94 ms /  1615 tokens' >srv.log
  local mid
  mid=$(wc -c <srv.log | tr -d ' ')
  printf '%s\n' \
    'srv  log_server_r: request: POST /v1/chat/completions 127.0.0.1 200' \
    '[52127] 0.22.455.959 I slot print_timing: id  0 | task 64 | prompt eval time =    1478.62 ms /    93 tokens (   15.90 ms per token,    62.90 tokens per second)' \
    '[52127] 0.22.455.969 I slot print_timing: id  0 | task 64 |        eval time =    2211.04 ms /    50 tokens (   45.12 ms per token,    22.16 tokens per second)' >>srv.log
  assert_eq "1645 14984 113 5232 2" "$(log_timings srv.log)"
  assert_eq "1552 13506 63 3021 1" "$(log_timings srv.log 0 "$mid")"
  assert_eq "93 1478 50 2211 1" "$(log_timings srv.log "$mid")"
  assert_eq 20.9 "$(tok_per_s 63 3021)"
  assert_eq - "$(tok_per_s 0 0)"
}

test_render_zot_home_fills_every_placeholder() {
  render_zot_home "$REPO_ROOT/config" zh qwen3-4b 16384 http://127.0.0.1:18080 || fail "render failed"
  local f
  for f in config.json auth.json models.json AGENTS.md; do assert_file "zh/$f"; done
  assert_not_contains "$(cat zh/*.json)" "@"
  assert_contains "$(cat zh/models.json)" '"contextWindow": 16384'
  assert_contains "$(cat zh/models.json)" '"maxTokens": 4096'
  assert_contains "$(cat zh/auth.json)" '"base_url": "http://127.0.0.1:18080"'
  assert_eq 600 "$(stat -c %a zh/auth.json)"
  jq . zh/config.json zh/auth.json zh/models.json >/dev/null || fail "rendered JSON is invalid"
  assert_eq 1024 "$(max_tokens 4096)"
}

test_verdict_thresholds() {
  assert_eq verified "$(verdict 20 18 15)"
  assert_eq unverified "$(verdict 20 18 14)" "too few tasks done"
  assert_eq unverified "$(verdict 20 17 17)" "tool calls not reliable enough"
  assert_eq unverified "$(verdict 20 10 5)"
  assert_eq broken "$(verdict 20 9 9)" "too few native calls"
  assert_eq broken "$(verdict 20 16 4)" "calls tools, but almost nothing gets done"
  assert_eq broken "$(verdict 20 0 0)"
}
