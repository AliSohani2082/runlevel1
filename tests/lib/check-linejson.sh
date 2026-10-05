#!/usr/bin/env bash
# Validate files against the canonical line-JSON rules (docs/contracts.md §1).
# Dev-only: requires jq. Usage: tests/lib/check-linejson.sh FILE...
# Prints one line per violation; exits non-zero if any file is invalid.
set -u

command -v jq >/dev/null 2>&1 || { echo "check-linejson: jq is required" >&2; exit 3; }

bad=0
err() { echo "$1: $2"; bad=1; }

for f in "$@"; do
  if ! jq -e . "$f" >/dev/null 2>&1; then err "$f" "not valid JSON"; continue; fi
  if LC_ALL=C grep -q "$(printf '\t')" "$f"; then err "$f" "contains tab characters"; fi
  if LC_ALL=C grep -q "$(printf '\r')" "$f"; then err "$f" "contains CR characters"; fi
  if [ -n "$(tail -c 1 "$f")" ]; then err "$f" "missing final newline"; fi

  # Strings: no quote, backslash or control characters inside values or keys.
  n=$(jq '[.. | strings | select(explode | any(. == 34 or . == 92 or . < 32))] | length' "$f")
  [ "$n" = 0 ] || err "$f" "$n string value(s) contain quote, backslash or control characters"
  # Numbers: non-negative integers only. No nulls anywhere.
  n=$(jq '[.. | numbers | select(. < 0 or . != floor)] | length' "$f")
  [ "$n" = 0 ] || err "$f" "$n number(s) are negative or non-integer"
  n=$(jq '[.. | nulls] | length' "$f")
  [ "$n" = 0 ] || err "$f" "contains null"

  # Top level is an object whose values are scalars, one-line objects, or
  # arrays of records ({"type": ...} first) with one record per line.
  jq -r 'to_entries[] | select(.value|type=="array") | .key' "$f" | while read -r key; do
    count=$(jq --arg k "$key" '.[$k] | length' "$f")
    nontype=$(jq --arg k "$key" '[.[$k][] | select(type != "object" or (keys_unsorted[0] != "type"))] | length' "$f")
    [ "$nontype" = 0 ] || echo "$f: array \"$key\" has $nontype element(s) that are not objects starting with \"type\""
    lines=0
    for t in $(jq -r --arg k "$key" '[.[$k][].type] | unique | .[]' "$f"); do
      c=$(LC_ALL=C grep -c "^ *{\"type\": \"$t\"" "$f")
      lines=$((lines + c))
    done
    [ "$lines" = "$count" ] || echo "$f: array \"$key\" has $count record(s) but $lines record line(s); each record must be on exactly one line"
  done | { if read -r first; then echo "$first"; cat; exit 1; fi; } || bad=1

  # Every record line must itself be a complete JSON object.
  while IFS= read -r line; do
    rec=${line%,}
    printf '%s' "$rec" | jq -e 'type == "object"' >/dev/null 2>&1 || err "$f" "record line is not a complete object: $line"
  done < <(LC_ALL=C grep '^ *{"type": ' "$f")

  # One-line object values (e.g. "provider") must sit on one line.
  for key in $(jq -r 'to_entries[] | select(.value|type=="object") | .key' "$f"); do
    LC_ALL=C grep -q "^  \"$key\": {.*},\{0,1\}$" "$f" || err "$f" "object \"$key\" must be written on one line"
  done
done
exit $bad
