#!/usr/bin/env bash
# Opt-in live Linear schema regression. `fm-linear-projection.sh schema-check`
# is unauthenticated but reaches https://api.linear.app/graphql, so it stays out
# of the default suite exactly like the other live-harness-optin regressions.
set -u

if [ "${FM_LINEAR_LIVE_SCHEMA:-0}" != 1 ]; then
  echo "skip: set FM_LINEAR_LIVE_SCHEMA=1 to run the live Linear schema check"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECTION="$ROOT/bin/fm-linear-projection.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v curl >/dev/null 2>&1 || fail "curl not found"

test_live_linear_schema_accepts_every_document() {
  local output
  output=$("$PROJECTION" schema-check) || fail "live Linear schema check failed: $output"
  printf '%s' "$output" | jq -e '.schema == "fm-linear-projection-schema-check.v1" and .documents == 4 and .valid == true' >/dev/null \
    || fail "live Linear schema check returned an invalid proof: $output"
  pass "all four GraphQL documents validate against Linear's live introspected schema"
}

test_live_linear_schema_accepts_every_document

echo "# fm-linear-schema-check-live.test.sh: all assertions passed"
