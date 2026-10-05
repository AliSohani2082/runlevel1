# shellcheck shell=bash
# Contract tests: the shared file formats from docs/contracts.md.
# The jq-based checks skip when jq is missing (e.g. in the bash:3.2 container);
# the pure-bash reader checks always run.

FIX="$REPO_ROOT/tests/fixtures"
CATALOG="$REPO_ROOT/models/catalog.json"

setup() {
  # shellcheck source=../lib/linejson.sh
  . "$REPO_ROOT/tests/lib/linejson.sh"
}

test_catalog_and_fixtures_are_canonical_line_json() {
  require_cmd jq grep
  run bash "$REPO_ROOT/tests/lib/check-linejson.sh" "$CATALOG" "$FIX"/*.json
  assert_eq 0 "$STATUS" "check-linejson output: $OUTPUT"
}

test_catalog_records_have_required_fields_and_valid_enums() {
  require_cmd jq
  run jq -r '
    .models[] |
    select(
      (.id | test("^[a-z0-9._-]+$") | not)
      or ([.type, .id, .menu, .params, .repo, .file, .revision, .chat_template, .license, .redistributable, .tool_calling, .status, .notes] | map(type == "string") | all | not)
      or ([.approx_bytes, .min_ram_mb, .ctx_size] | map(type == "number" and . > 0) | all | not)
      or (.redistributable | IN("yes", "no", "unknown") | not)
      or (.tool_calling | IN("verified", "unverified", "broken") | not)
      or (.status | IN("available", "unverified", "dropped") | not)
      or (.status == "available" and (.file == "" or .redistributable == "no"))
    ) | .id' "$CATALOG"
  assert_eq 0 "$STATUS"
  assert_eq "" "$OUTPUT" "catalog records with invalid fields"
}

test_catalog_default_exists_and_is_available() {
  require_cmd jq
  run jq -r '.default as $d | [.models[] | select(.id == $d and .status == "available")] | length' "$CATALOG"
  assert_eq 1 "$OUTPUT"
}

test_catalog_ids_are_unique() {
  require_cmd jq
  run jq -r '[.models[].id] | (length == (unique | length))' "$CATALOG"
  assert_eq true "$OUTPUT"
}

test_reader_extracts_top_level_scalars() {
  assert_eq 1 "$(lj_top "$FIX/manifest.local.json" schema)"
  assert_eq local "$(lj_top "$FIX/manifest.local.json" backend)"
  assert_eq 0.1.0-dev "$(lj_top "$FIX/manifest.local.json" llmkit_version)"
  assert_eq qwen2.5-coder-7b-instruct "$(lj_top "$FIX/manifest.local.json" default_model)"
  assert_eq "" "$(lj_top "$FIX/manifest.online.json" default_model)"
}

test_reader_extracts_one_line_objects() {
  local p s
  p=$(lj_object "$FIX/manifest.online.json" provider)
  assert_eq anthropic "$(lj_str "$p" id)"
  assert_eq ANTHROPIC_API_KEY "$(lj_str "$p" key_env)"
  assert_eq false "$(lj_num "$p" key_embedded)"
  s=$(lj_object "$FIX/manifest.local.json" server)
  assert_eq 8080 "$(lj_num "$s" port)"
  assert_eq 127.0.0.1 "$(lj_str "$s" host)"
}

test_reader_iterates_records_by_type() {
  local n=0 line ids=""
  while IFS= read -r line; do
    n=$((n + 1))
  done < <(lj_records "$FIX/manifest.local.json" file)
  assert_eq 12 "$n" "file records"
  while IFS= read -r line; do
    ids="$ids $(lj_str "$line" id)"
  done < <(lj_records "$FIX/manifest.local.json" model)
  assert_eq " qwen2.5-coder-7b-instruct phi3-sysadmin" "$ids"
  assert_eq "" "$(lj_records "$FIX/manifest.online.json" model)" "online manifest has no models"
}

test_reader_handles_large_sizes_and_paths() {
  local line
  line=$(lj_records "$FIX/manifest.local.json" file | while IFS= read -r l; do
    case $(lj_str "$l" path) in (models/qwen2.5-coder-7b-instruct.gguf) printf '%s\n' "$l" ;; esac
  done)
  assert_eq 4683073536 "$(lj_num "$line" size)"
  assert_eq data "$(lj_str "$line" mode)"
  assert_eq model "$(lj_str "$line" component)"
}

test_reader_does_not_confuse_similar_keys() {
  local line='{"type": "x", "key_id": "wrong", "id": "right", "sizes": 1, "size": 2}'
  assert_eq right "$(lj_str "$line" id)"
  assert_eq 2 "$(lj_num "$line" size)"
}

test_scripts_carry_the_repo_version() {
  local v f line
  v=$(cat "$REPO_ROOT/VERSION")
  for f in setup.sh llm-kit.sh; do
    line=""
    while IFS= read -r l; do
      case $l in LLMKIT_VERSION=*) line=$l; break ;; esac
    done <"$REPO_ROOT/$f"
    assert_eq "LLMKIT_VERSION=\"$v\"" "$line" "$f must define LLMKIT_VERSION matching VERSION"
  done
}
