#!/usr/bin/env bash
# Contract for verify_channel_document (src/span-auspex/verify-lib.sh), auspex ADR 0066. The fixtures are
# real: the channel document and bundle from auspex's first signed publish-release.yml run, and, as the
# wrong signer, v0.11.0's release manifest.json and bundle. Real cosign verifies them offline against the
# pinned trusted_root.json. A stub cosign then drives the schema checks, which no real signature reaches.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY_LIB="${REPO_ROOT}/src/span-auspex/verify-lib.sh"
FIX="${REPO_ROOT}/tests/fixtures/channel"
DOC="${FIX}/channels.json"
DOC_BUNDLE="${FIX}/channels.json.cosign.bundle"
MANIFEST="${FIX}/manifest.json"
MANIFEST_BUNDLE="${FIX}/manifest.json.cosign.bundle"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The library deletes a cosign or jq it downloaded after each verify, so provision them once onto PATH.
mkdir -p "$WORK/bin"
(
  # shellcheck source=src/span-auspex/verify-lib.sh
  . "$VERIFY_LIB"
  ensure_cosign >/dev/null
  ensure_jq >/dev/null
  [ "$COSIGN_BIN" = cosign ] || mv "$COSIGN_BIN" "$WORK/bin/cosign"
  [ "$JQ_BIN" = jq ] || mv "$JQ_BIN" "$WORK/bin/jq"
)
PATH="$WORK/bin:$PATH"

mkdir -p "$WORK/stub"
printf '#!/bin/sh\nexit 0\n' >"$WORK/stub/cosign"
chmod 0755 "$WORK/stub/cosign"

pass=0
fail=0
# expect <label> <want-exit> <cmd…> — runs cmd in a subshell that sources the library, whose functions exit.
expect() {
  local label="$1" want="$2" rc=0
  shift 2
  (
    # shellcheck source=src/span-auspex/verify-lib.sh
    . "$VERIFY_LIB"
    "$@"
  ) >"$WORK/out.log" 2>&1 || rc=$?
  if [ "$rc" = "$want" ]; then
    echo "ok   - ${label}"
    pass=$((pass + 1))
  else
    echo "FAIL - ${label} (exit ${rc}, want ${want})"
    sed 's/^/    /' "$WORK/out.log"
    fail=$((fail + 1))
  fi
}

stubbed() { PATH="$WORK/stub:$PATH" "$@"; }

sequence_is() { # <want> <doc> <bundle>
  local want="$1"
  shift
  verify_channel_document "$@" >/dev/null
  # shellcheck disable=SC2031 # runs inside expect's subshell, after the verify sets it
  [ "$CHANNEL_SEQUENCE" = "$want" ]
}

doc_json() { # <name> <json> — a document for the stub-cosign cases; prints its path.
  printf '%s\n' "$2" >"$WORK/$1.json"
  printf '%s' "$WORK/$1.json"
}

echo "==> real signatures"
expect "the signed channel document verifies" 0 verify_channel_document "$DOC" "$DOC_BUNDLE"
expect "it sets CHANNEL_SEQUENCE to the document's" 0 sequence_is 1 "$DOC" "$DOC_BUNDLE"
expect "a --min-sequence equal to the document's passes" 0 \
  verify_channel_document "$DOC" "$DOC_BUNDLE" --min-sequence 1
expect "a sequence below the last one accepted is refused as a replay" 19 \
  verify_channel_document "$DOC" "$DOC_BUNDLE" --min-sequence 2

sed 's/"stable": "v0.11.0"/"stable": "v0.10.0"/' "$DOC" >"$WORK/tampered.json"
cmp -s "$DOC" "$WORK/tampered.json" && {
  echo "FAIL - the tamper didn't change the document"
  exit 1
}
expect "a tampered document fails" 13 verify_channel_document "$WORK/tampered.json" "$DOC_BUNDLE"

expect "the release manifest verifies under the release identity" 0 \
  verify_cosign_bundle "$MANIFEST" "$MANIFEST_BUNDLE"
expect "the release manifest fails as a channel document (wrong signer)" 13 \
  verify_channel_document "$MANIFEST" "$MANIFEST_BUNDLE"
expect "the channel document fails under the release identity (cross)" 13 \
  verify_cosign_bundle "$DOC" "$DOC_BUNDLE"

echo "==> arguments"
expect "a missing bundle fails as unfetched" 11 verify_channel_document "$DOC" "$WORK/absent.bundle"
expect "one argument is a usage error" 2 verify_channel_document "$DOC"
expect "a non-numeric --min-sequence is a usage error" 2 \
  verify_channel_document "$DOC" "$DOC_BUNDLE" --min-sequence abc
expect "--min-sequence without a value is a usage error" 2 \
  verify_channel_document "$DOC" "$DOC_BUNDLE" --min-sequence
expect "an unknown option is a usage error" 2 verify_channel_document "$DOC" "$DOC_BUNDLE" --channel stable

echo "==> schema (stub cosign)"
ok_doc='{"schema":1,"sequence":7,"issued_at":"2026-11-02T18:00:00Z","latest":"v0.11.0","stable":"v0.10.1","minimum":"v0.9.1"}'
expect "a well-formed document passes" 0 stubbed verify_channel_document "$(doc_json ok "$ok_doc")" "$DOC_BUNDLE"
expect "a document with every channel unset passes" 0 stubbed verify_channel_document \
  "$(doc_json unset '{"schema":1,"sequence":1,"issued_at":null,"latest":null,"stable":null,"minimum":null}')" "$DOC_BUNDLE"
for bad in \
  'schema 2|{"schema":2,"sequence":7,"latest":"v0.11.0","stable":"v0.10.1","minimum":null}' \
  'sequence 0|{"schema":1,"sequence":0,"latest":"v0.11.0","stable":"v0.10.1","minimum":null}' \
  'a string sequence|{"schema":1,"sequence":"7","latest":"v0.11.0","stable":"v0.10.1","minimum":null}' \
  'a fractional sequence|{"schema":1,"sequence":7.5,"latest":"v0.11.0","stable":"v0.10.1","minimum":null}' \
  'a sequence past 2^53|{"schema":1,"sequence":1e30,"latest":"v0.11.0","stable":"v0.10.1","minimum":null}' \
  'a tag without a patch number|{"schema":1,"sequence":7,"latest":"v0.11","stable":"v0.10.1","minimum":null}' \
  'a tag with build metadata|{"schema":1,"sequence":7,"latest":"v0.11.0+build","stable":"v0.10.1","minimum":null}' \
  'a tag without the v|{"schema":1,"sequence":7,"latest":"v0.11.0","stable":"0.10.1","minimum":null}' \
  'a minimum without a stable|{"schema":1,"sequence":7,"latest":"v0.11.0","stable":null,"minimum":"v0.9.1"}' \
  'not JSON|not json'; do
  expect "refused: ${bad%%|*}" 18 stubbed verify_channel_document "$(doc_json bad "${bad#*|}")" "$DOC_BUNDLE"
done

echo ""
echo "channel-verify-test: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
