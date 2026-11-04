#!/usr/bin/env bash
# verify_channel_document (auspex ADR 0066) against real fixtures: auspex's first signed channel document, and
# v0.11.0's release manifest as the wrong signer. A stub cosign drives the schema checks no real signature reaches.
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

# Most of the library's verifies delete a cosign or jq they downloaded, so provision them once onto PATH.
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

# A PATH with jq but no cosign, and a cosign URL that refuses connections, for the download-reuse cases:
# any attempt to download cosign there fails with exit 15.
mkdir -p "$WORK/nocosign"
ln -s "$(command -v jq)" "$WORK/nocosign/jq"
NOCOSIGN_PATH="$WORK/nocosign:/usr/bin:/bin"
if PATH="$NOCOSIGN_PATH" command -v cosign >/dev/null 2>&1; then
  echo "FAIL - cosign is in /usr/bin or /bin, so the download-reuse cases can't run"
  exit 1
fi
cp "$(command -v cosign)" "$WORK/cosign-original"

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

# Stands in for a cosign the library downloaded earlier in the run: a fresh copy per case, because a
# finishing verify deletes it. set -e is off inside expect's subshell, so each step checks its own status.
with_downloaded_cosign() {
  PATH="$NOCOSIGN_PATH"
  COSIGN_BASE_URL="http://127.0.0.1:9"
  COSIGN_CLEANUP="$(mktemp "$WORK/downloaded-cosign.XXXXXX")" || return 1
  cp "$WORK/cosign-original" "$COSIGN_CLEANUP" && chmod 0755 "$COSIGN_CLEANUP" || return 1
  "$@"
}

reuses_download() {
  local want="$COSIGN_CLEANUP"
  ensure_cosign || return 1
  # shellcheck disable=SC2031 # runs inside expect's subshell, after ensure_cosign sets it
  [ "$COSIGN_BIN" = "$want" ]
}

nothing_to_reuse() {
  COSIGN_CLEANUP=""
  ensure_cosign
}

keeps_download() {
  verify_channel_document "$DOC" "$DOC_BUNDLE" >/dev/null || return 1
  verify_cosign_bundle "$MANIFEST" "$MANIFEST_BUNDLE" >/dev/null
}

cleanup_removes_downloads() {
  local cosign="$COSIGN_CLEANUP" jq="$WORK/downloaded-jq"
  [ -x "$cosign" ] && printf 'jq' >"$jq" || return 1
  JQ_CLEANUP="$jq"
  verify_lib_cleanup
  [ ! -e "$cosign" ] && [ ! -e "$jq" ] && [ -z "$COSIGN_CLEANUP$JQ_CLEANUP" ]
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
expect "a --min-sequence past 64 bits is still refused" 19 \
  verify_channel_document "$DOC" "$DOC_BUNDLE" --min-sequence 99999999999999999999
expect "a --min-sequence with leading zeros compares as its value" 0 \
  verify_channel_document "$DOC" "$DOC_BUNDLE" --min-sequence 001
expect "a --min-sequence of 0 passes" 0 verify_channel_document "$DOC" "$DOC_BUNDLE" --min-sequence 0

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

echo "==> downloaded cosign"
expect "a cosign downloaded earlier in the run is reused, not fetched again" 0 \
  with_downloaded_cosign reuses_download
expect "the channel verify leaves it for the .pkg verify that follows" 0 with_downloaded_cosign keeps_download
expect "with nothing to reuse, the unreachable URL fails provisioning" 15 \
  with_downloaded_cosign nothing_to_reuse
expect "verify_lib_cleanup removes the downloads and forgets them" 0 with_downloaded_cosign cleanup_removes_downloads

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
for good in \
  'a minimum equal to stable|{"schema":1,"sequence":7,"latest":"v0.11.0","stable":"v0.10.1","minimum":"v0.10.1"}' \
  'a minimum below stable by number, not text|{"schema":1,"sequence":7,"latest":"v0.11.0","stable":"v0.10.0","minimum":"v0.9.1"}' \
  'a pre-release minimum below its release|{"schema":1,"sequence":7,"latest":"v1.0.0","stable":"v1.0.0","minimum":"v1.0.0-rc.1"}' \
  'a pre-release minimum below by number|{"schema":1,"sequence":7,"latest":"v1.0.0","stable":"v1.0.0-rc.10","minimum":"v1.0.0-rc.2"}' \
  'a numeric pre-release minimum below an alphanumeric one|{"schema":1,"sequence":7,"latest":"v1.0.0","stable":"v1.0.0-rc","minimum":"v1.0.0-1"}'; do
  expect "accepted: ${good%%|*}" 0 stubbed verify_channel_document "$(doc_json good "${good#*|}")" "$DOC_BUNDLE"
done
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
  'a minimum above stable|{"schema":1,"sequence":7,"latest":"v0.11.0","stable":"v0.10.1","minimum":"v0.11.0"}' \
  'a minimum above stable by patch|{"schema":1,"sequence":7,"latest":"v0.11.0","stable":"v0.10.1","minimum":"v0.10.2"}' \
  'a release minimum above its pre-release stable|{"schema":1,"sequence":7,"latest":"v1.0.0","stable":"v1.0.0-rc.1","minimum":"v1.0.0"}' \
  'a numerically higher pre-release minimum|{"schema":1,"sequence":7,"latest":"v1.0.0","stable":"v1.0.0-rc.2","minimum":"v1.0.0-rc.10"}' \
  'a lexically higher pre-release minimum|{"schema":1,"sequence":7,"latest":"v1.0.0","stable":"v1.0.0-rc10","minimum":"v1.0.0-rc2"}' \
  'an alphanumeric minimum above a numeric pre-release|{"schema":1,"sequence":7,"latest":"v1.0.0","stable":"v1.0.0-1","minimum":"v1.0.0-rc"}' \
  'a longer pre-release minimum above its prefix|{"schema":1,"sequence":7,"latest":"v1.0.0","stable":"v1.0.0-rc","minimum":"v1.0.0-rc.1"}' \
  'not JSON|not json'; do
  expect "refused: ${bad%%|*}" 18 stubbed verify_channel_document "$(doc_json bad "${bad#*|}")" "$DOC_BUNDLE"
done

echo ""
echo "channel-verify-test: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
