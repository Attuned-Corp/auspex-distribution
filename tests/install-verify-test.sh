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
VERIFY_LIB="${REPO_ROOT}/src/span-auspex/verify-lib.sh"
[ -f "$INSTALL_SH" ] || {
  echo "FAIL: installer not found at ${INSTALL_SH}" >&2
  exit 1
}
[ -f "$VERIFY_LIB" ] || {
  echo "FAIL: shared verify library not found at ${VERIFY_LIB}" >&2
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
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" >/dev/null 2>&1 || true; fi
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

# ---- verify: cosign (the default) — resolve → fetch-by-digest → verify (ADR 0047) --------------------
# A pure-bash harness can't mint a real keyless signature (that's the Docker smoke / a real rc tag), so it
# drives the cosign wiring with a STUB cosign (verify-blob → configurable exit) and the host's REAL jq to
# exercise: the manifest.json (+ .cosign.bundle) fetch + cosign-verify, the version-annotation guard (the
# version-substitution defense), the unique application/octet-stream descriptor lookup, and the by-digest
# blob fetch + self-verify (sha256(bytes) == the signed digest). It then proves the pinned-hash gate on a
# DOWNLOADED cosign fails closed. The real cryptographic verify is covered by the Docker smoke / rc tag.
STUB_DIR="$WORK/stubbin"
mkdir -p "$STUB_DIR"
make_stub_cosign() { # <verify-blob exit code>
  {
    echo '#!/usr/bin/env bash'
    echo "exit $1"
  } >"$STUB_DIR/cosign"
  chmod 0755 "$STUB_DIR/cosign"
}

# Build the real download-host CAS layout: a signed manifest.json (+ .cosign.bundle) at the version root
# (which resolve_binary_digest derives as dirname^3 of the binaryUri) that binds test/linux/amd64 → the
# blob's digest, and the content-addressed blob itself at blobs/sha256/<digest>. The version-path binary is
# kept present for realism though the cosign tier now installs the blob, not it.
COSIGN_RELDIR="releases/test/linux/amd64"
BIN_SIZE="$(wc -c <"$WEBROOT/auspex" | tr -d ' ')"
setup_manifest_layout() { # <manifest-version> <blob: good|bad|absent>
  local mver="$1" blob="$2"
  mkdir -p "$WEBROOT/releases/test" "$WEBROOT/blobs/sha256" "$WEBROOT/$COSIGN_RELDIR"
  cp "$WEBROOT/auspex" "$WEBROOT/$COSIGN_RELDIR/auspex"
  cat >"$WEBROOT/releases/test/manifest.json" <<JSON
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/octet-stream",
      "digest": "sha256:${GOOD_SUM}",
      "size": ${BIN_SIZE},
      "platform": { "os": "linux", "architecture": "amd64" },
      "annotations": { "org.opencontainers.image.title": "auspex_test_linux_amd64" }
    }
  ],
  "annotations": { "org.opencontainers.image.version": "${mver}" }
}
JSON
  printf 'dummy-new-format-bundle\n' >"$WEBROOT/releases/test/manifest.json.cosign.bundle"
  rm -f "$WEBROOT/blobs/sha256/${GOOD_SUM}"
  case "$blob" in
    good) cp "$WEBROOT/auspex" "$WEBROOT/blobs/sha256/${GOOD_SUM}" ;;
    bad) printf 'tampered-blob-bytes-%s' "$(date +%s)" >"$WEBROOT/blobs/sha256/${GOOD_SUM}" ;;
    absent) : ;; # no blob at all
  esac
}
cosign_check() { # <label> <expect ok|fail> <stub-exit> <manifest-version> <blob good|bad|absent>
  local label="$1" expect="$2" stub_exit="$3" mver="$4" blob="$5" bin_dest share_dir rc=0
  setup_manifest_layout "$mver" "$blob"
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
  # A success must install the BLOB bytes (== the fixture binary); a refusal must leave nothing on PATH.
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

echo "==> install.sh verify: cosign — resolve → fetch-by-digest → verify (ADR 0047)"
if command -v jq >/dev/null 2>&1; then
  cosign_check "cosign-verifies"             ok   0 test  good     # stub cosign OK + blob self-verifies → install
  cosign_check "cosign-bad-signature"        fail 1 test  good     # cosign rejects the manifest → fail closed
  cosign_check "cosign-version-substitution" fail 0 other good     # signed manifest is for another tag → refuse
  cosign_check "cosign-blob-tampered"        fail 0 test  bad      # blob bytes ≠ signed digest → self-verify fails
  cosign_check "cosign-blob-absent"          fail 0 test  absent   # by-digest blob missing → fetch fails closed
else
  echo "skip [cosign matrix]: jq not available to parse the fixture manifest (the recipe auto-provisions a pinned jq in the wild)"
fi

# Pinned-hash gate on a DOWNLOADED cosign: with no cosign on PATH, ensure_cosign (called first by
# resolve_binary_digest) fetches from AUSPEX_COSIGN_BASE_URL and checks the hardcoded per-arch SHA-256 —
# serve wrong bytes → must fail closed BEFORE any manifest parse (so this needs no jq). Linux-only
# (ensure_cosign auto-provisions only on Linux) and only meaningful when cosign isn't already on PATH.
if [ "$(uname -s)" = "Linux" ] && ! command -v cosign >/dev/null 2>&1; then
  cver="$(sed -n "s/^COSIGN_VERSION='\\(.*\\)'/\\1/p" "$VERIFY_LIB" | head -1)"
  case "$(uname -m)" in x86_64 | amd64) carch=amd64 ;; aarch64 | arm64) carch=arm64 ;; *) carch="" ;; esac
  if [ -n "$cver" ] && [ -n "$carch" ]; then
    setup_manifest_layout test good
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

# ---- curl|sh bootstrap (AC1/AC2/AC3) -----------------------------------------------------------------
# The bootstrap shares the SAME verify recipe (src/span-auspex/verify-lib.sh). Drive it two ways: the
# repo-checkout form (bootstrap/bootstrap.sh sources the lib) AND the assembled release form
# (dist/auspex-install.sh with the lib inlined + trusted_root.json embedded) — proving the assembled
# installer verifies fail-closed with its EMBEDDED anchor, not just the checkout. Same fixture + stub cosign.
BOOTSTRAP_SH="${REPO_ROOT}/bootstrap/bootstrap.sh"
ASSEMBLED_SH="${WORK}/auspex-install.sh"
"${REPO_ROOT}/bootstrap/assemble.sh" "$ASSEMBLED_SH" >/dev/null

boot_check() { # <label> <expect ok|fail> <script> <verify-mode> <url> <sidecar good|bad|none> <extra-path>
  local label="$1" expect="$2" script="$3" mode="$4" url="$5" sidecar="$6" extra_path="${7:-}"
  case "$sidecar" in
    good) printf '%s  auspex\n' "$GOOD_SUM" >"$WEBROOT/auspex.sha256" ;;
    bad) printf '%s  auspex\n' "0000000000000000000000000000000000000000000000000000000000000000" >"$WEBROOT/auspex.sha256" ;;
    none) rm -f "$WEBROOT/auspex.sha256" ;;
  esac
  local bootdir="$WORK/bootdest" rc=0
  rm -rf "$bootdir"
  env -i PATH="${extra_path:+$extra_path:}$PATH" \
    bash "$script" --url "$url" --verify "$mode" --bin-dir "$bootdir" >"$WORK/out.log" 2>&1 || rc=$?
  local got="ok"
  [ "$rc" -ne 0 ] && got="fail"
  if [ "$got" != "$expect" ]; then
    echo "FAIL [$label]: expected $expect but ${got}ed (rc=$rc)" >&2
    sed 's/^/    /' "$WORK/out.log" >&2
    fail=$((fail + 1))
    return
  fi
  if [ "$expect" = "ok" ] && { [ ! -x "$bootdir/auspex" ] || ! cmp -s "$WEBROOT/auspex" "$bootdir/auspex"; }; then
    echo "FAIL [$label]: reported success but ${bootdir}/auspex is missing/wrong" >&2
    fail=$((fail + 1))
    return
  fi
  if [ "$expect" = "fail" ] && [ -e "$bootdir/auspex" ]; then
    echo "FAIL [$label]: refused install still left a binary (must fail closed)" >&2
    fail=$((fail + 1))
    return
  fi
  echo "ok [$label]: bootstrap ${got} as expected"
  pass=$((pass + 1))
}

echo "==> curl|sh bootstrap contract (checkout + assembled)"
boot_check "boot-checksum-match"      ok   "$BOOTSTRAP_SH" checksum "${BASE}/auspex" good
boot_check "boot-checksum-mismatch"   fail "$BOOTSTRAP_SH" checksum "${BASE}/auspex" bad
boot_check "boot-none-skips"          ok   "$BOOTSTRAP_SH" none     "${BASE}/auspex" none

# cosign tier (stub cosign on PATH): checkout form uses the on-disk trusted_root.json; assembled form uses
# its EMBEDDED root (AUSPEX_TRUSTED_ROOT set by the assembled preamble). Both resolve the signed manifest,
# fetch the content-addressed blob by digest, and self-verify — failing closed on a bad manifest signature
# or a tampered blob. Needs the host's jq to parse the fixture manifest (skipped when absent).
if command -v jq >/dev/null 2>&1; then
  setup_manifest_layout test good
  make_stub_cosign 0
  boot_check "boot-cosign-checkout"      ok   "$BOOTSTRAP_SH" cosign "${BASE}/${COSIGN_RELDIR}/auspex" good "$STUB_DIR"
  boot_check "boot-cosign-assembled"     ok   "$ASSEMBLED_SH" cosign "${BASE}/${COSIGN_RELDIR}/auspex" good "$STUB_DIR"
  setup_manifest_layout test bad
  boot_check "boot-cosign-blob-tampered" fail "$ASSEMBLED_SH" cosign "${BASE}/${COSIGN_RELDIR}/auspex" good "$STUB_DIR"
  make_stub_cosign 1
  setup_manifest_layout test good
  boot_check "boot-cosign-bad-signature" fail "$ASSEMBLED_SH" cosign "${BASE}/${COSIGN_RELDIR}/auspex" good "$STUB_DIR"
else
  echo "skip [boot cosign matrix]: jq not available to parse the fixture manifest"
fi

# ---- MDM verify-before-install gate (AC7) ------------------------------------------------------------
# The gate reuses the SAME recipe via verify_cosign_bundle (bundle-direct over the .pkg/.msi bytes — no
# checksums.txt indirection). A pure-bash harness can't mint a real signature, so drive the cosign wiring
# with the STUB cosign (verify-blob → configurable exit) and assert the FAIL-CLOSED behavior + the exact
# exit-code contract (AC2) the MDM wrapper keys on: 0 verified · 13 bad-sig/identity · 11 fetch (no bundle).
GATE_SH="${REPO_ROOT}/mdm/verify-gate.sh"

gate_check() { # <label> <expect-rc> <stub-exit|nostub> <bundle: good|missing> [verify-mode]
  local label="$1" expect_rc="$2" stub="$3" bundlemode="$4" mode="${5:-cosign}" rc=0
  local pkg="$WORK/auspex.pkg" bundle="$WORK/auspex.pkg.cosign.bundle"
  printf 'fake-auspex-pkg-%s' "$(date +%s)" >"$pkg"
  if [ "$bundlemode" = good ]; then printf 'dummy-per-artifact-bundle\n' >"$bundle"; else rm -f "$bundle"; fi
  local path_pre=""
  [ "$stub" != nostub ] && { make_stub_cosign "$stub"; path_pre="${STUB_DIR}:"; }
  env -i PATH="${path_pre}$PATH" \
    bash "$GATE_SH" --installer "$pkg" --verify "$mode" >"$WORK/out.log" 2>&1 || rc=$?
  if [ "$rc" != "$expect_rc" ]; then
    echo "FAIL [$label]: expected rc=$expect_rc but got rc=$rc" >&2
    sed 's/^/    /' "$WORK/out.log" >&2
    fail=$((fail + 1))
    return
  fi
  echo "ok [$label]: gate rc=$rc as expected"
  pass=$((pass + 1))
}

echo "==> MDM verify-before-install gate contract"
gate_check "gate-verifies"       0  0      good           # stub cosign OK  → verified, safe to install
gate_check "gate-bad-signature"  13 1      good           # cosign rejects  → EX_COSIGN, fail closed
gate_check "gate-missing-bundle" 11 0      missing         # no .cosign.bundle → EX_FETCH, fail closed
gate_check "gate-none-skips"     0  nostub missing none    # explicit opt-out skips verify (needs no cosign)

echo "==> ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || exit 1
