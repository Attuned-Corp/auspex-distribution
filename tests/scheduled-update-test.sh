#!/usr/bin/env bash
# shellcheck disable=SC2016  # checks are single-quoted on purpose: expect evals them after each run
# mdm/scheduled-update.sh against real signatures: the signed channel fixture, and the release-signed manifest
# fixture standing in for the .pkg (verify_cosign_bundle checks any bytes against their bundle). The pinned
# cosign is downloaded once and seeded into each case's state directory; every run's own cosign download
# points at a refused port, so a case passes only if the cache is used. installer and pkgutil are stubs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_ROOT}/mdm/scheduled-update.sh"
VERIFY_LIB="${REPO_ROOT}/src/span-auspex/verify-lib.sh"
FIX="${REPO_ROOT}/tests/fixtures/channel"
UPDATE_BASH="${UPDATE_BASH:-bash}" # the macOS CI job runs the script under /bin/bash 3.2
# ASSEMBLED=1 runs the released form instead: bootstrap/assemble.sh's single file, as the loader runs it.
# The loader cases always run the released loader on stdin, as an MDM runs it.
ASSEMBLED="${ASSEMBLED:-}"

command -v python3 >/dev/null 2>&1 || {
  echo "SKIP: python3 not available to serve the fixture"
  exit 0
}

WORK="$(mktemp -d)"
WEBROOT="$WORK/web"
PORT_FILE="$WORK/port"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# The pinned cosign (and jq where the system has none), downloaded with no cosign or jq on PATH so the
# library fetches the pinned builds whose hashes the script's cache check expects.
mkdir -p "$WORK/tools"
(
  PATH="/usr/bin:/bin"
  # shellcheck source=src/span-auspex/verify-lib.sh
  . "$VERIFY_LIB"
  ensure_cosign >/dev/null
  mv "$COSIGN_CLEANUP" "$WORK/tools/cosign"
  if [ ! -x /usr/bin/jq ]; then
    ensure_jq >/dev/null
    mv "$JQ_CLEANUP" "$WORK/tools/jq"
  fi
)

mkdir -p "$WEBROOT/releases/v0.11.0/darwin" "$WEBROOT/cosign/v-any"
cp "$FIX/channels.json" "$FIX/channels.json.cosign.bundle" "$WEBROOT/releases/"
PKG="$WEBROOT/releases/v0.11.0/darwin/auspex_0.11.0_darwin_universal.pkg"
cp "$FIX/manifest.json" "$PKG"
cp "$FIX/manifest.json.cosign.bundle" "$PKG.cosign.bundle"

python3 - "$WEBROOT" "$PORT_FILE" >/dev/null 2>&1 <<'PY' &
import sys, os, http.server, socketserver
os.chdir(sys.argv[1])
class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass
with socketserver.TCPServer(("127.0.0.1", 0), Q) as httpd:
    with open(sys.argv[2], "w") as f:
        f.write(str(httpd.server_address[1]))
    httpd.serve_forever()
PY
SERVER_PID=$!
disown "$SERVER_PID" 2>/dev/null || true
for _ in $(seq 1 50); do
  [ -s "$PORT_FILE" ] && break
  sleep 0.1
done
[ -s "$PORT_FILE" ] || {
  echo "FAIL: fixture HTTP server never reported its port" >&2
  exit 1
}
BASE="http://127.0.0.1:$(cat "$PORT_FILE")"

sha_of() { (shasum -a 256 "$1" 2>/dev/null || sha256sum "$1") | cut -d ' ' -f 1; }

RELEASE_TAG=test-release "$REPO_ROOT/bootstrap/assemble.sh" "$WORK/dist/auspex-install.sh" >/dev/null
BUILT="$WORK/dist/auspex-scheduled-update.sh"
LOADER_SRC="$WORK/dist/auspex-scheduled-update-loader.sh"
mkdir -p "$WEBROOT/loader"
cp "$BUILT" "$WEBROOT/loader/auspex-scheduled-update.sh"
if [ -n "$ASSEMBLED" ]; then
  SCRIPT="$BUILT"
  echo "==> the assembled script ($(wc -c <"$BUILT" | tr -d ' ') bytes)"
fi

# Stubs. pkgutil reports $CASE/receipt as the installed version; installer logs its call, then sets the
# receipt to $CASE/installer-sets (default 0.11.0) and exits with $CASE/installer-rc (default 0).
mkdir -p "$WORK/stub"
cat >"$WORK/stub/pkgutil" <<'SH'
#!/bin/sh
[ -f "$STUB_CASE/receipt" ] || exit 1
printf 'package-id: app.span.auspex\nversion: %s\nvolume: /\n' "$(cat "$STUB_CASE/receipt")"
SH
cat >"$WORK/stub/installer" <<'SH'
#!/bin/sh
echo "$*" >>"$STUB_CASE/installer.log"
rc="$(cat "$STUB_CASE/installer-rc" 2>/dev/null || echo 0)"
[ "$rc" = 0 ] || exit "$rc"
cat "$STUB_CASE/installer-sets" 2>/dev/null >"$STUB_CASE/receipt" || echo 0.11.0 >"$STUB_CASE/receipt"
SH
cat >"$WORK/stub/planted" <<'SH'
#!/bin/sh
touch "$STUB_CASE/planted-$(basename "$0")-ran"
exit 0
SH
chmod 0755 "$WORK/stub/"*
mkdir -p "$WORK/planted"
cp "$WORK/stub/planted" "$WORK/planted/cosign"

pass=0
fail=0
CASE=""

new_case() {
  CASE="$(mktemp -d "$WORK/case.XXXXXX")"
  mkdir -m 0700 "$CASE/state"
  mkdir -p "$CASE/state/bin"
  cp "$WORK/tools/"* "$CASE/state/bin/"
}

VIA_LOADER=""
update() {
  local cmd=("$UPDATE_BASH" "$SCRIPT") input=/dev/null settings=(AUSPEX_BASE_URL="$BASE")
  if [ -n "$VIA_LOADER" ]; then # an MDM sets no settings: they come from the loader's own lines
    cmd=("$UPDATE_BASH" -s)
    input="$WORK/loader.sh"
    settings=()
  fi
  env -i HOME="$CASE" PATH="/usr/bin:/bin" STUB_CASE="$CASE" \
    ${settings[@]+"${settings[@]}"} \
    AUSPEX_UPDATE_STATE_DIR="$CASE/state" \
    AUSPEX_UPDATE_ALLOW_NONROOT=1 \
    AUSPEX_UPDATE_PKGUTIL="$WORK/stub/pkgutil" \
    AUSPEX_UPDATE_INSTALLER="$WORK/stub/installer" \
    AUSPEX_COSIGN_BASE_URL="http://127.0.0.1:9" \
    AUSPEX_JQ_BASE_URL="http://127.0.0.1:9" \
    "$@" "${cmd[@]}" <"$input" >"$CASE/out.log" 2>&1
}

# expect <label> <want-exit> [VAR=value…] -- <check…> — runs update, then each check in this shell.
expect() {
  local label="$1" want="$2" rc=0 problem=""
  shift 2
  local env_args=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    env_args+=("$1")
    shift
  done
  [ "$#" -gt 0 ] && shift
  update ${env_args[@]+"${env_args[@]}"} || rc=$?
  if [ "$rc" != "$want" ]; then
    problem="exit ${rc}, want ${want}"
  else
    while [ "$#" -gt 0 ]; do
      eval "$1" || {
        problem="check failed: $1"
        break
      }
      shift
    done
  fi
  if [ -z "$problem" ]; then
    echo "ok   - ${label}"
    pass=$((pass + 1))
  else
    echo "FAIL - ${label} (${problem})"
    sed 's/^/    /' "$CASE/out.log"
    fail=$((fail + 1))
  fi
}

installed_is() { [ "$(cat "$CASE/receipt" 2>/dev/null)" = "$1" ]; }
not_installed() { [ ! -s "$CASE/installer.log" ]; }
said() { grep -qF "$1" "$CASE/out.log"; }
last_line_says() { tail -n 1 "$CASE/out.log" | grep -qF "$1"; }
sequence_is() { [ "$(cat "$CASE/state/sequence" 2>/dev/null)" = "$1" ]; }
tidy() { [ ! -e "$CASE/state/staging" ] && [ ! -e "$CASE/state/tmp" ] && [ ! -e "$CASE/state/lock" ]; }
failed_with() { last_line_says "failed with exit $1 (exit codes: mdm/README.md)"; }
cosign_is_pinned() { cmp -s "$CASE/state/bin/cosign" "$WORK/tools/cosign"; }
cached_is_pinned() { cmp -s "$CASE/state/scheduled-update.sh" "$BUILT"; }
installed_verified_pkg() { [ "$(cat "$CASE/installer.log")" = "-pkg $CASE/state/staging/auspex.pkg -target /" ]; }

echo "==> outcomes"
new_case
expect "first install: no receipt installs stable" 0 -- \
  'installed_is 0.11.0' 'last_line_says "installed auspex v0.11.0 from stable (was not installed)"' \
  'sequence_is 1' tidy '! said "unbound variable"' installed_verified_pkg '! said "failed with exit"'
rm -f "$CASE/installer.log"
expect "a second run is up to date and installs nothing" 0 -- \
  not_installed 'last_line_says "auspex v0.11.0 is up to date with stable"'

new_case
echo 0.10.0 >"$CASE/receipt"
expect "an older install upgrades" 0 -- 'installed_is 0.11.0' 'last_line_says "(was v0.10.0)"'

new_case
echo 0.12.1 >"$CASE/receipt"
expect "a newer install is ahead and exits 0" 0 -- not_installed 'installed_is 0.12.1' \
  'last_line_says "auspex v0.12.1 is ahead of stable (v0.11.0); nothing to do"'

new_case
echo 0.10.0 >"$CASE/receipt"
expect "latest is honored" 0 AUSPEX_CHANNEL=latest -- 'installed_is 0.11.0' 'said "from latest"'

echo "==> refusals"
new_case
printf ' ' >>"$WEBROOT/releases/channels.json"
expect "a tampered channel document" 13 -- not_installed tidy 'failed_with 13'
cp "$FIX/channels.json" "$WEBROOT/releases/"

new_case
cp "$FIX/manifest.json" "$WEBROOT/releases/channels.json"
cp "$FIX/manifest.json.cosign.bundle" "$WEBROOT/releases/channels.json.cosign.bundle"
expect "a release-signed document as the channel (wrong signer)" 13 -- not_installed
cp "$FIX/channels.json" "$FIX/channels.json.cosign.bundle" "$WEBROOT/releases/"

new_case
echo 2 >"$CASE/state/sequence"
expect "a replayed lower sequence" 19 -- not_installed 'sequence_is 2'

new_case
echo junk >"$CASE/state/sequence"
expect "a corrupt sequence record" 21 -- not_installed 'said "does not hold a sequence number"' 'failed_with 21'

new_case
printf ' ' >>"$PKG"
expect "a tampered .pkg is never installed" 13 -- not_installed tidy
cp "$FIX/manifest.json" "$PKG"

new_case
mv "$PKG.cosign.bundle" "$WORK/held.bundle"
expect "a .pkg without its bundle" 11 -- not_installed
mv "$WORK/held.bundle" "$PKG.cosign.bundle"

new_case
echo 1 >"$CASE/installer-rc"
expect "a failing installer" 22 -- 'said "installer failed for auspex v0.11.0"' tidy

new_case
echo 0.10.0 >"$CASE/installer-sets"
expect "a receipt that doesn't name the target after install" 23 -- \
  'said "but the package receipt says 0.10.0"' 'failed_with 23'

new_case
echo garbage >"$CASE/receipt"
expect "an unreadable receipt version" 16 -- not_installed

echo "==> cached cosign"
new_case
rm -f "$CASE/state/bin/cosign"
expect "an empty cache with an unreachable download fails provisioning" 15 -- not_installed

new_case
printf 'tampered' >"$CASE/state/bin/cosign"
expect "a tampered cache is never run, and can't be replaced offline" 15 -- not_installed

new_case
printf 'tampered' >"$CASE/state/bin/cosign"
COS_OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
COS_ARCH="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"
COS_VER="$(sed -n "s/^COSIGN_VERSION='\(.*\)'$/\1/p" "$VERIFY_LIB")"
mkdir -p "$WEBROOT/cosign/$COS_VER"
cp "$WORK/tools/cosign" "$WEBROOT/cosign/$COS_VER/cosign-$COS_OS-$COS_ARCH"
expect "a tampered cache is replaced by the pinned download" 0 AUSPEX_COSIGN_BASE_URL="$BASE/cosign" -- \
  cosign_is_pinned 'installed_is 0.11.0'

new_case
rm -f "$CASE/state/bin/cosign"
expect "a cosign on the caller's PATH is never run" 15 PATH="$WORK/planted:/usr/bin:/bin" -- \
  '[ ! -e "$CASE/planted-cosign-ran" ]' not_installed

echo "==> cached jq"
if [ -x /usr/bin/jq ]; then
  echo "skip - cached jq: the script prefers this host's /usr/bin/jq (CI reruns with it removed)"
else
  new_case
  expect "a cached jq is used, not downloaded" 0 -- 'installed_is 0.11.0' '! said "provisioning pinned jq"'

  new_case
  cp "$WORK/stub/planted" "$CASE/state/bin/jq"
  expect "a tampered jq cache is never run, and can't be replaced offline" 17 -- \
    '[ ! -e "$CASE/planted-jq-ran" ]' not_installed

  new_case
  cp "$WORK/stub/planted" "$CASE/state/bin/jq"
  JQ_OS="$(uname -s | tr '[:upper:]' '[:lower:]' | sed 's/darwin/macos/')"
  JQ_VER="$(sed -n "s/^JQ_VERSION='\(.*\)'$/\1/p" "$VERIFY_LIB")"
  mkdir -p "$WEBROOT/jq/$JQ_VER"
  cp "$WORK/tools/jq" "$WEBROOT/jq/$JQ_VER/jq-$JQ_OS-$COS_ARCH"
  expect "a tampered jq cache is replaced by the pinned download" 0 AUSPEX_JQ_BASE_URL="$BASE/jq" -- \
    'cmp -s "$CASE/state/bin/jq" "$WORK/tools/jq"' '[ ! -e "$CASE/planted-jq-ran" ]' 'installed_is 0.11.0'
fi

echo "==> state and lock"
new_case
chmod 0755 "$CASE/state"
expect "a state directory others can read" 21 -- not_installed

new_case
mv "$CASE/state" "$CASE/real-state"
ln -s "$CASE/real-state" "$CASE/state"
expect "a linked state directory" 21 -- not_installed

new_case
mkdir "$CASE/state/lock"
echo "$$" >"$CASE/state/lock/pid"
expect "a lock held by a live run exits 0 and does nothing" 0 -- not_installed \
  'last_line_says "another run is in progress; nothing to do"' '[ -d "$CASE/state/lock" ]' \
  '! said "failed with exit"'

new_case
mkdir "$CASE/state/lock"
sh -c 'echo $$' >"$CASE/state/lock/pid"
expect "a lock left by a run that died is taken over" 0 -- 'installed_is 0.11.0' tidy

echo "==> settings"
new_case
expect "no base URL" 2 AUSPEX_BASE_URL= -- not_installed
expect "an unknown channel, named without quotes" 2 AUSPEX_CHANNEL=beta -- not_installed \
  'said "AUSPEX_CHANNEL must be stable or latest, not beta"' '! grep -q "'"'"'" "$CASE/out.log"' 'failed_with 2'
expect "a cleartext non-loopback host" 2 AUSPEX_BASE_URL=http://example.com -- not_installed
if [ "$(id -u)" != 0 ]; then
  expect "not root" 16 AUSPEX_UPDATE_ALLOW_NONROOT= -- not_installed
fi

echo "==> loader"
holds() { # <label> <command…>
  if "${@:2}"; then
    echo "ok   - $1"
    pass=$((pass + 1))
  else
    echo "FAIL - $1"
    fail=$((fail + 1))
  fi
}
# loader_for <channel> — the released loader with the fixture host and <channel> in its settings lines, and
# its download pointed at the fixture (loopback http in place of its https-only flags).
loader_for() {
  sed -e "s|^AUSPEX_BASE_URL=\"\" |AUSPEX_BASE_URL=\"${BASE}\" |" \
    -e "s|^AUSPEX_CHANNEL=\"stable\" |AUSPEX_CHANNEL=\"$1\" |" \
    -e "s|^SCRIPT_URL=.*|SCRIPT_URL=\"${BASE}/loader/auspex-scheduled-update.sh\"|" \
    -e "s|--proto '=https' --proto-redir '=https'|--proto '=http'|" "$LOADER_SRC" >"$WORK/loader.sh"
}
holds "the released loader pins the released script by SHA-256" grep -qx "SCRIPT_SHA256=\"$(sha_of "$BUILT")\"" "$LOADER_SRC"
holds "the released loader downloads from its own release" \
  grep -qx 'SCRIPT_URL="https://github.com/Attuned-Corp/auspex-distribution/releases/download/test-release/auspex-scheduled-update.sh"' "$LOADER_SRC"
holds "the released loader downloads over https only" grep -qF -- "--proto '=https' --proto-redir '=https'" "$LOADER_SRC"
holds "the released loader is short enough to read" [ "$(wc -l <"$LOADER_SRC")" -le 45 ]

VIA_LOADER=1
loader_for stable
new_case
expect "the loader runs the pinned script with its own settings, and caches it" 0 -- \
  'installed_is 0.11.0' 'last_line_says "installed auspex v0.11.0 from stable"' tidy cached_is_pinned

loader_for latest
new_case
expect "the loader passes its channel through" 0 -- 'installed_is 0.11.0' 'said "from latest"'

loader_for beta
new_case
expect "a bad channel fails in the script, with one failure line" 2 -- not_installed \
  'said "not beta"' 'failed_with 2' '[ "$(grep -c "failed with exit" "$CASE/out.log")" = 1 ]'

loader_for stable
printf ' ' >>"$WEBROOT/loader/auspex-scheduled-update.sh"
new_case
expect "a script that does not match the pin is never run" 12 -- not_installed \
  'said "running nothing"' 'failed_with 12' '[ ! -e "$CASE/state/sequence" ]' '[ ! -e "$CASE/state/scheduled-update.sh" ]'
mv "$WEBROOT/loader/auspex-scheduled-update.sh" "$WORK/held.sh"
new_case
expect "a script that cannot be downloaded is never run" 11 -- not_installed 'failed_with 11' \
  '[ ! -e "$CASE/state/sequence" ]'
new_case
cp "$BUILT" "$CASE/state/scheduled-update.sh"
expect "a cached script that matches the pin runs without a download" 0 -- 'installed_is 0.11.0'
new_case
printf 'echo planted\n' >"$CASE/state/scheduled-update.sh"
expect "a cached script that does not match the pin is never run" 11 -- not_installed '! said planted' \
  'failed_with 11'
new_case
chmod 0755 "$CASE/state"
cp "$BUILT" "$CASE/state/scheduled-update.sh"
expect "a cache in a state directory others can read is not used" 11 -- not_installed 'failed_with 11'
cp "$BUILT" "$WEBROOT/loader/auspex-scheduled-update.sh"
new_case
printf 'echo stale\n' >"$CASE/state/scheduled-update.sh"
expect "a stale cached script is replaced by the pinned download" 0 -- 'installed_is 0.11.0' '! said stale' \
  cached_is_pinned
VIA_LOADER=""

echo "==> decisions"
# decides <label> <want> <channel> <installed> <json>
decides() {
  local label="$1" want="$2" got
  printf '%s' "$5" >"$WORK/doc.json"
  got="$(AUSPEX_UPDATE_NO_MAIN=1 "$UPDATE_BASH" -c '. "$1"; PATH="$2:$PATH"; decide "$3" "$4" "$5"' _ \
    "$SCRIPT" "$WORK/tools" "$WORK/doc.json" "$3" "$4" 2>&1)" || got="error: $got"
  if [ "$got" = "$want" ]; then
    echo "ok   - decide: ${label}"
    pass=$((pass + 1))
  else
    echo "FAIL - decide: ${label} (got '${got}', want '${want}')"
    fail=$((fail + 1))
  fi
}
doc() { printf '{"schema":1,"sequence":1,"latest":%s,"stable":%s,"minimum":%s}' "$1" "$2" "$3"; }
decides "a channel naming no release" "none -" stable 0.11.0 "$(doc '"v0.11.0"' null null)"
decides "a pre-release stable" "prerelease v0.13.0-rc1" stable 0.11.0 "$(doc '"v0.13.0-rc1"' '"v0.13.0-rc1"' null)"
decides "a pre-release latest is allowed" "upgrade v0.13.0-rc1" latest 0.12.1 "$(doc '"v0.13.0-rc1"' '"v0.12.1"' null)"
decides "a target below the minimum" "below-minimum v0.10.0" latest 0.9.0 "$(doc '"v0.10.0"' '"v0.12.0"' '"v0.11.0"')"
decides "an install below the minimum still upgrades" "upgrade v0.12.0" stable 0.9.0 "$(doc '"v0.12.0"' '"v0.12.0"' '"v0.11.0"')"
decides "nothing installed" "install v0.11.0" stable "" "$(doc '"v0.11.0"' '"v0.11.0"' null)"
decides "versions compare as numbers" "upgrade v0.10.0" stable 0.9.0 "$(doc '"v0.10.0"' '"v0.10.0"' null)"
decides "a release candidate sorts below its release" "upgrade v0.11.0" stable 0.11.0-rc1 "$(doc '"v0.11.0"' '"v0.11.0"' null)"
decides "an installed release candidate of a later version is ahead" "ahead v0.11.0" stable 0.12.0-rc1 "$(doc '"v0.11.0"' '"v0.11.0"' null)"

echo "==> the .pkg signature names its release"
# verifies <label> <want-rc> <tag> — the v0.11.0-signed fixture, checked as <tag>'s .pkg
verifies() {
  local label="$1" want="$2" rc=0
  AUSPEX_UPDATE_NO_MAIN=1 "$UPDATE_BASH" -c '. "$1"; PATH="$2:$PATH"; verify_release_pkg "$3" "$3.cosign.bundle" "$4"' _ \
    "$SCRIPT" "$WORK/tools" "$PKG" "$3" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "$want" ]; then
    echo "ok   - ${label}"
    pass=$((pass + 1))
  else
    echo "FAIL - ${label} (exit ${rc}, want ${want})"
    fail=$((fail + 1))
  fi
}
verifies "a .pkg verifies as its own release" 0 v0.11.0
verifies "an older release's .pkg is refused as a newer one" 13 v0.12.1
verifies "the tag must match whole, not as a prefix" 13 v0.11

echo ""
echo "scheduled-update-test: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
