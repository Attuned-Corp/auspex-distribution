#!/usr/bin/env bash
# Regression for the Dev Container Feature installer's download-integrity gate (ADR 0045). Unlike the
# full devcontainer smoke (Docker + the devcontainer CLI), this is a pure bash+HTTP test: it serves a
# fake binary + its .sha256 sidecar over localhost and drives src/span-auspex/
# install.sh through every verify: mode, asserting the CONTRACT — a tampered/absent checksum must fail
# CLOSED (nothing installed), a matching one must install, and verify: none must skip the check. It runs
# the installer off-root via the AUSPEX_BIN_DEST / AUSPEX_SHARE_DIR overrides, so it needs no privileges.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/src/span-auspex/install.sh"
[ -f "$INSTALL_SH" ] || {
  echo "FAIL: installer not found at ${INSTALL_SH}" >&2
  exit 1
}

# Skip (do not fail) where the harness's own deps are missing — the same fetch tools install.sh needs.
command -v python3 >/dev/null 2>&1 || {
  echo "SKIP: python3 not available to serve the fixture"
  exit 0
}
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || {
  echo "SKIP: neither curl nor wget available (install.sh needs one to download)"
  exit 0
}

WORK="$(mktemp -d)"
WEBROOT="$WORK/web"
mkdir -p "$WEBROOT"
PORT_FILE="$WORK/port"
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# The fixture binary is opaque bytes — install.sh (hookScope: user, no auspexHome) never EXECUTES it, it
# only downloads → verifies → chmod → records; so its content just has to be stable and non-empty.
printf 'fake-auspex-binary-%s' "$(date +%s)" >"$WEBROOT/auspex"
GOOD_SUM="$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$WEBROOT/auspex"; else shasum -a 256 "$WEBROOT/auspex"; fi | awk '{print $1}')"

# Serve $WEBROOT on an ephemeral port; report it via PORT_FILE. Quiet handler so the log doesn't drown
# the test output.
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
disown "$SERVER_PID" 2>/dev/null || true # suppress the shell's "Terminated" job-control notice on cleanup

for _ in $(seq 1 50); do
  [ -s "$PORT_FILE" ] && break
  sleep 0.1
done
[ -s "$PORT_FILE" ] || {
  echo "FAIL: fixture HTTP server never reported its port" >&2
  exit 1
}
PORT="$(cat "$PORT_FILE")"
BASE="http://127.0.0.1:${PORT}"

pass=0
fail=0
check() { # <label> <expect: ok|fail> <verify-mode> <write-sidecar: good|bad|none>
  local label="$1" expect="$2" mode="$3" sidecar="$4"
  case "$sidecar" in
    good) printf '%s  auspex\n' "$GOOD_SUM" >"$WEBROOT/auspex.sha256" ;;
    bad) printf '%s  auspex\n' "0000000000000000000000000000000000000000000000000000000000000000" >"$WEBROOT/auspex.sha256" ;;
    none) rm -f "$WEBROOT/auspex.sha256" ;;
  esac

  local bin_dest share_dir rc=0
  bin_dest="$WORK/dest/auspex"
  share_dir="$WORK/share"
  rm -rf "$WORK/dest" "$share_dir"
  mkdir -p "$WORK/dest"

  env -i PATH="$PATH" \
    BINARYURI="${BASE}/auspex" \
    VERSION="test" \
    VERIFY="$mode" \
    HOOKSCOPE="user" \
    AUSPEX_BIN_DEST="$bin_dest" \
    AUSPEX_SHARE_DIR="$share_dir" \
    bash "$INSTALL_SH" >"$WORK/out.log" 2>&1 || rc=$?

  local got="ok"
  [ "$rc" -ne 0 ] && got="fail"

  if [ "$got" != "$expect" ]; then
    echo "FAIL [$label]: expected install to $expect but it ${got}ed (rc=$rc)" >&2
    sed 's/^/    /' "$WORK/out.log" >&2
    fail=$((fail + 1))
    return
  fi
  # A refused install must leave NOTHING on PATH; a successful one must place the exact bytes, executable.
  if [ "$expect" = "ok" ]; then
    if [ ! -x "$bin_dest" ]; then
      echo "FAIL [$label]: install reported success but ${bin_dest} is missing or not executable" >&2
      fail=$((fail + 1))
      return
    fi
    if ! cmp -s "$WEBROOT/auspex" "$bin_dest"; then
      echo "FAIL [$label]: installed bytes differ from the served binary" >&2
      fail=$((fail + 1))
      return
    fi
  else
    if [ -e "$bin_dest" ]; then
      echo "FAIL [$label]: refused install still left a binary at ${bin_dest} (must fail closed)" >&2
      fail=$((fail + 1))
      return
    fi
  fi
  echo "ok [$label]: install ${got} as expected"
  pass=$((pass + 1))
}

echo "==> install.sh download-verify contract (fixture at ${BASE})"
check "checksum-match"          ok   checksum good
check "checksum-mismatch"       fail checksum bad
check "checksum-missing-sidecar" fail checksum none
check "verify-none-skips"       ok   none     none

# ---- verify: cosign (the default) --------------------------------------------------------------------
# A pure-bash harness can't mint a real keyless signature (that's the Docker smoke / a real rc tag), so it
# drives the cosign wiring with a STUB cosign (verify-blob → configurable exit): version-root derivation,
# the checksums.txt + .cosign.bundle fetch, the pinned trusted-root presence gate, and the digest-membership
# check. It then proves the pinned-hash gate on a DOWNLOADED cosign fails closed. The real cryptographic
# verify is covered by the Docker smoke and the release rc-tag validation.
STUB_DIR="$WORK/stubbin"
mkdir -p "$STUB_DIR"

# Build the real download-host layout: /releases/<v>/<os>/<arch>/auspex (+ .sha256) with checksums.txt
# (+ .cosign.bundle) at the version root, which verify_cosign derives as dirname^3 of the binaryUri.
COSIGN_RELDIR="releases/test/linux/amd64"
setup_cosign_layout() { # <checksums-contains-digest: yes|no>
  mkdir -p "$WEBROOT/$COSIGN_RELDIR"
  cp "$WEBROOT/auspex" "$WEBROOT/$COSIGN_RELDIR/auspex"
  printf '%s  auspex\n' "$GOOD_SUM" >"$WEBROOT/$COSIGN_RELDIR/auspex.sha256"
  if [ "$1" = "yes" ]; then
    printf '%s  auspex_test_linux_amd64\n' "$GOOD_SUM" >"$WEBROOT/releases/test/checksums.txt"
  else
    printf '%s  auspex_test_linux_amd64\n' "0000000000000000000000000000000000000000000000000000000000000000" >"$WEBROOT/releases/test/checksums.txt"
  fi
  printf 'dummy-new-format-bundle\n' >"$WEBROOT/releases/test/checksums.txt.cosign.bundle"
}
make_stub_cosign() { # <verify-blob exit code>
  {
    echo '#!/usr/bin/env bash'
    echo "exit $1"
  } >"$STUB_DIR/cosign"
  chmod 0755 "$STUB_DIR/cosign"
}
cosign_check() { # <label> <expect ok|fail> <stub-exit> <checksums-has-digest yes|no>
  local label="$1" expect="$2" stub_exit="$3" with_digest="$4" bin_dest share_dir rc=0
  setup_cosign_layout "$with_digest"
  make_stub_cosign "$stub_exit"
  bin_dest="$WORK/dest/auspex"
  share_dir="$WORK/share"
  rm -rf "$WORK/dest" "$share_dir"
  mkdir -p "$WORK/dest"
  env -i PATH="${STUB_DIR}:${PATH}" \
    BINARYURI="${BASE}/${COSIGN_RELDIR}/auspex" \
    VERSION="test" \
    VERIFY="cosign" \
    HOOKSCOPE="user" \
    AUSPEX_BIN_DEST="$bin_dest" \
    AUSPEX_SHARE_DIR="$share_dir" \
    bash "$INSTALL_SH" >"$WORK/out.log" 2>&1 || rc=$?
  local got="ok"
  [ "$rc" -ne 0 ] && got="fail"
  if [ "$got" != "$expect" ]; then
    echo "FAIL [$label]: expected install to $expect but it ${got}ed (rc=$rc)" >&2
    sed 's/^/    /' "$WORK/out.log" >&2
    fail=$((fail + 1))
    return
  fi
  if [ "$expect" = "ok" ] && { [ ! -x "$bin_dest" ] || ! cmp -s "$WEBROOT/auspex" "$bin_dest"; }; then
    echo "FAIL [$label]: install reported success but ${bin_dest} is missing/wrong" >&2
    fail=$((fail + 1))
    return
  fi
  if [ "$expect" = "fail" ] && [ -e "$bin_dest" ]; then
    echo "FAIL [$label]: refused install still left a binary at ${bin_dest} (must fail closed)" >&2
    fail=$((fail + 1))
    return
  fi
  echo "ok [$label]: install ${got} as expected"
  pass=$((pass + 1))
}

cosign_check "cosign-stub-verifies"   ok   0 yes
cosign_check "cosign-digest-absent"   fail 0 no
cosign_check "cosign-bad-signature"   fail 1 yes

# Pinned-hash gate on a DOWNLOADED cosign: with no cosign on PATH, ensure_cosign fetches from
# AUSPEX_COSIGN_BASE_URL and checks the hardcoded per-arch SHA-256 — serve wrong bytes → must fail closed.
# Linux-only (ensure_cosign auto-provisions only on Linux) and only meaningful when cosign isn't on PATH.
if [ "$(uname -s)" = "Linux" ] && ! command -v cosign >/dev/null 2>&1; then
  cver="$(sed -n "s/^COSIGN_VERSION='\\(.*\\)'/\\1/p" "$INSTALL_SH" | head -1)"
  case "$(uname -m)" in x86_64 | amd64) carch=amd64 ;; aarch64 | arm64) carch=arm64 ;; *) carch="" ;; esac
  if [ -n "$cver" ] && [ -n "$carch" ]; then
    setup_cosign_layout yes
    mkdir -p "$WEBROOT/cosigndl/$cver"
    printf 'not-a-real-cosign-binary\n' >"$WEBROOT/cosigndl/$cver/cosign-linux-$carch"
    bin_dest="$WORK/dest/auspex"
    share_dir="$WORK/share"
    rm -rf "$WORK/dest" "$share_dir"
    mkdir -p "$WORK/dest"
    rc=0
    env -i PATH="$PATH" \
      BINARYURI="${BASE}/${COSIGN_RELDIR}/auspex" \
      VERSION="test" \
      VERIFY="cosign" \
      HOOKSCOPE="user" \
      AUSPEX_COSIGN_BASE_URL="${BASE}/cosigndl" \
      AUSPEX_BIN_DEST="$bin_dest" \
      AUSPEX_SHARE_DIR="$share_dir" \
      bash "$INSTALL_SH" >"$WORK/out.log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] && [ ! -e "$bin_dest" ]; then
      echo "ok [cosign-pinned-hash-gate]: tampered downloaded cosign refused (fail closed)"
      pass=$((pass + 1))
    else
      echo "FAIL [cosign-pinned-hash-gate]: expected fail-closed but rc=$rc, bin present=$([ -e "$bin_dest" ] && echo yes || echo no)" >&2
      sed 's/^/    /' "$WORK/out.log" >&2
      fail=$((fail + 1))
    fi
  else
    echo "skip [cosign-pinned-hash-gate]: could not resolve pinned cosign version/arch"
  fi
else
  echo "skip [cosign-pinned-hash-gate]: needs Linux without a cosign already on PATH"
fi

echo "==> ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || exit 1
