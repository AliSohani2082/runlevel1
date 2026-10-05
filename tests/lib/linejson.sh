# shellcheck shell=bash
# Reference reader for the canonical line-JSON format (docs/contracts.md §1).
# Pure bash 3.2: no grep/sed/awk/jq. llm-kit.sh carries its own copy of these
# functions (it must be self-contained); tests/contracts keeps both honest.

# lj_str LINE KEY - print the string value of KEY found in LINE.
lj_str() {
  local re="\"$2\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
  [[ $1 =~ $re ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# lj_num LINE KEY - print the integer or boolean value of KEY found in LINE.
lj_num() {
  local re="\"$2\"[[:space:]]*:[[:space:]]*([0-9]+|true|false)"
  [[ $1 =~ $re ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# lj_top FILE KEY - print a top-level scalar (string, integer or boolean).
lj_top() {
  local line re_s re_n
  re_s="^  \"$2\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
  re_n="^  \"$2\"[[:space:]]*:[[:space:]]*([0-9]+|true|false)"
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ $re_s ]] || [[ $line =~ $re_n ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done <"$1"
  return 1
}

# lj_object FILE KEY - print the single-line top-level object value of KEY
# (e.g. "provider"), for use with lj_str / lj_num.
lj_object() {
  local line re
  re="^  \"$2\"[[:space:]]*:[[:space:]]*(\{.*\})"
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ $re ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done <"$1"
  return 1
}

# lj_records FILE TYPE - print every record line whose "type" is TYPE.
lj_records() {
  local line re
  re="^[[:space:]]*\{\"type\"[[:space:]]*:[[:space:]]*\"$2\""
  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line =~ $re ]] && printf '%s\n' "$line"
  done <"$1"
  return 0
}
