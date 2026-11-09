# shellcheck shell=bash
# auspex MDM scheduled update (macOS). An MDM runs it as root on a schedule (a Mosyle Custom Command, for
# example). Each run reads the signed release channel document and, when the channel names a newer release
# than the installed package, installs that release's .pkg, verified fail-closed with the same recipe as
# mdm/verify-gate.sh. It also does the first install on a Mac without auspex. See mdm/README.md.
#
# Settings, from the environment or the assignments at the top of the assembled script:
#   AUSPEX_BASE_URL  your auspex download host (https://…), from your install instructions. Required.
#   AUSPEX_CHANNEL   stable (the default) or latest.
#
# It keeps its state in AUSPEX_UPDATE_STATE_DIR (default /Library/Application Support/auspex-update): the
# pinned cosign, cached so a run doesn't download it again, and the highest channel sequence accepted, so a
# replayed older document is refused (auspex ADR 0066 §3). auspex's uninstall-managed.sh removes it.
set -euo pipefail

# A root script must never run a cosign or jq a user could plant on an inherited PATH (a Homebrew prefix is
# user-writable). The verify recipe uses whatever cosign and jq it finds on PATH.
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
umask 077

AUSPEX_VERIFY_LOG_PREFIX="auspex update"

if [ -z "${_AUSPEX_VERIFY_LIB_SOURCED:-}" ]; then
  _UPDATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck source=src/span-auspex/verify-lib.sh
  # shellcheck disable=SC1091  # runtime-resolved; source= aids `shellcheck -x`
  . "${_UPDATE_DIR}/../src/span-auspex/verify-lib.sh"
fi

# Exit codes beyond the verify recipe's (11, 13, 15, 16, 17, 18, 19; all in mdm/README.md). 0 also covers
# ahead of the channel and another run holding the lock.
AUSPEX_UPDATE_EX_REFUSED=20 # the channel names a target this script won't install (a pre-release stable, below minimum)
AUSPEX_UPDATE_EX_STATE=21   # the state directory or its sequence record isn't safe to use
AUSPEX_UPDATE_EX_INSTALL=22 # installer -pkg failed
AUSPEX_UPDATE_EX_RECEIPT=23 # after the install, the package receipt doesn't name the target

AUSPEX_CHANNEL="${AUSPEX_CHANNEL:-stable}"
AUSPEX_BASE_URL="${AUSPEX_BASE_URL:-}"
PKG_ID="app.span.auspex"
STATE_DIR="${AUSPEX_UPDATE_STATE_DIR:-/Library/Application Support/auspex-update}"
# Overridable for tests. Root's environment comes from root's caller, so this opens nothing to a user.
PKGUTIL="${AUSPEX_UPDATE_PKGUTIL:-/usr/sbin/pkgutil}"
INSTALLER="${AUSPEX_UPDATE_INSTALLER:-/usr/sbin/installer}"

LOCK_HELD=""

result() { echo "${AUSPEX_VERIFY_LOG_PREFIX}: $*"; }
refuse() { # <exit-code> <message>
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: $2" >&2
  exit "$1"
}

owner_and_mode() { stat -c '%u %a' "$1" 2>/dev/null || stat -f '%u %Lp' "$1"; }

prepare_state() {
  if [ ! -e "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ]; then
    mkdir -m 0700 "$STATE_DIR" || refuse "$AUSPEX_UPDATE_EX_STATE" "could not create ${STATE_DIR}"
  fi
  if [ -L "$STATE_DIR" ] || [ ! -d "$STATE_DIR" ] || [ "$(owner_and_mode "$STATE_DIR")" != "$(id -u) 700" ]; then
    refuse "$AUSPEX_UPDATE_EX_STATE" "${STATE_DIR} must be a directory owned by $(id -un) with mode 0700, not a link — refusing to use it"
  fi
  mkdir -p "$STATE_DIR/bin" "$STATE_DIR/tmp"
  TMPDIR="$STATE_DIR/tmp"
  export TMPDIR
}

# mkdir is atomic, so one run holds the lock. A lock whose holder has exited is taken over; an empty one is
# another run between mkdir and writing its pid, unless it is an hour old (that run died there).
acquire_lock() {
  local lock="$STATE_DIR/lock" pid
  if ! mkdir "$lock" 2>/dev/null; then
    pid="$(cat "$lock/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then return 1; fi
    if [ -z "$pid" ] && [ -z "$(find "$lock" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then return 1; fi
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || return 1
  fi
  echo "$$" >"$lock/pid"
  LOCK_HELD=1
}

cleanup() {
  local rc=$?
  rm -rf "$STATE_DIR/staging" "$STATE_DIR/tmp"
  [ -z "$LOCK_HELD" ] || rm -rf "$STATE_DIR/lock"
  # The assembled script decodes its embedded trust root to a temp file (bootstrap/assemble.sh).
  [ -z "${_AUSPEX_EMBEDDED_ROOT:-}" ] || rm -f "$_AUSPEX_EMBEDDED_ROOT"
  return "$rc"
}

pinned_sha256() { # <COSIGN|JQ> — the verify recipe's pin for this os/arch, or empty
  local os arch var
  case "$(uname -s)" in
    Darwin) os="darwin"; [ "$1" = JQ ] && os="macos" ;; # jq's release assets say macos
    Linux) os="linux" ;;
    *) return 0 ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch="amd64" ;;
    aarch64 | arm64) arch="arm64" ;;
    *) return 0 ;;
  esac
  var="${1}_SHA256_${os}_${arch}"
  printf '%s' "${!var:-}"
}

# Use a root-owned system copy if the fixed PATH has one (macOS 15+ ships /usr/bin/jq). Otherwise keep the
# pinned download in the state directory, hash-checked before every run's use, so a run rarely downloads.
provision_tool() { # <cosign|jq>
  local name="$1" cache="$STATE_DIR/bin/$1" pin
  command -v "$name" >/dev/null 2>&1 && return 0
  pin="$(pinned_sha256 "$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')")"
  if [ -n "$pin" ] && [ -f "$cache" ] && [ ! -L "$cache" ] && [ "$(sha256_of "$cache")" = "$pin" ]; then
    return 0
  fi
  rm -f "$cache"
  if [ "$name" = cosign ]; then
    ensure_cosign
    mv -f "$COSIGN_CLEANUP" "$cache"
    COSIGN_BIN="" COSIGN_CLEANUP=""
  else
    ensure_jq
    mv -f "$JQ_CLEANUP" "$cache"
    JQ_BIN="" JQ_CLEANUP=""
  fi
}

# Prints the installed package's version (0.12.1), or nothing when no auspex package is installed.
installed_version() {
  { "$PKGUTIL" --pkg-info "$PKG_ID" 2>/dev/null || true; } | sed -n 's/^version: //p' | head -n 1
}

read_channel() { # <doc-out>
  local doc="$1" bundle="$1.cosign.bundle" record="$STATE_DIR/sequence" min=""
  local url="${AUSPEX_BASE_URL%/}/releases/channels.json"
  fetch "$url" "$doc" || refuse "$AUSPEX_VERIFY_EX_FETCH" "could not fetch ${url}"
  fetch "${url}.cosign.bundle" "$bundle" || refuse "$AUSPEX_VERIFY_EX_FETCH" "could not fetch ${url}.cosign.bundle"
  if [ -f "$record" ]; then
    min="$(cat "$record")"
    case "$min" in
      "" | *[!0-9]*) refuse "$AUSPEX_UPDATE_EX_STATE" "${record} doesn't hold a sequence number; remove it to start over" ;;
    esac
  fi
  if [ -n "$min" ]; then
    verify_channel_document "$doc" "$bundle" --min-sequence "$min"
  else
    verify_channel_document "$doc" "$bundle"
  fi
  printf '%s\n' "$CHANNEL_SEQUENCE" >"$record.new"
  mv -f "$record.new" "$record"
}

# Prints "<action> <target>": none (no release named), prerelease or below-minimum (refusals, auspex ADR 0066
# §2), install, current, ahead or upgrade. <installed> has no leading v, and is empty when nothing is installed.
decide() { # <doc> <channel> <installed>
  # shellcheck disable=SC2016  # jq variables, deliberately single-quoted (not shell)
  jq -r --arg channel "$2" --arg installed "$3" "$AUSPEX_JQ_SEMVER"'
    .[$channel] as $t
    | (if $installed == "" then null else "v" + $installed end) as $i
    | if $t == null then "none -"
      elif $channel == "stable" and ($t | parts | .pre != []) then "prerelease \($t)"
      elif .minimum != null and vlt($t; .minimum) then "below-minimum \($t)"
      elif $i == null then "install \($t)"
      elif $i == $t then "current \($t)"
      elif vlt($t; $i) then "ahead \($t)"
      else "upgrade \($t)" end' "$1"
}

# The library accepts any release's signature. Pin it to <tag>'s, or a genuine older .pkg served at the
# target's URL would verify and downgrade the Mac before the receipt check could notice.
verify_release_pkg() { # <file> <bundle_src> <tag>
  local COSIGN_IDENTITY_RE="${COSIGN_IDENTITY_RE%%@refs/tags/*}@refs/tags/${3//./\\.}\$"
  verify_cosign_bundle "$1" "$2"
}

install_release() { # <tag>
  local tag="$1" staging="$STATE_DIR/staging" url
  url="${AUSPEX_BASE_URL%/}/releases/${tag}/darwin/auspex_${tag#v}_darwin_universal.pkg"
  rm -rf "$staging"
  mkdir -m 0700 "$staging"
  fetch "$url" "$staging/auspex.pkg" || refuse "$AUSPEX_VERIFY_EX_FETCH" "could not fetch ${url}"
  verify_release_pkg "$staging/auspex.pkg" "${url}.cosign.bundle" "$tag"
  "$INSTALLER" -pkg "$staging/auspex.pkg" -target / ||
    refuse "$AUSPEX_UPDATE_EX_INSTALL" "installer failed for auspex ${tag}"
  [ "v$(installed_version)" = "$tag" ] ||
    refuse "$AUSPEX_UPDATE_EX_RECEIPT" "installed auspex ${tag}, but the package receipt says '$(installed_version)'"
}

main() {
  [ "$(id -u)" -eq 0 ] || [ -n "${AUSPEX_UPDATE_ALLOW_NONROOT:-}" ] ||
    refuse "$AUSPEX_VERIFY_EX_ENV" "run as root, from an MDM or sudo"
  case "$AUSPEX_CHANNEL" in
    stable | latest) ;;
    *) refuse "$AUSPEX_VERIFY_EX_USAGE" "AUSPEX_CHANNEL must be stable or latest, not '${AUSPEX_CHANNEL}'" ;;
  esac
  case "$AUSPEX_BASE_URL" in
    https://*) ;;
    http://*) is_loopback_url "$AUSPEX_BASE_URL" ||
      refuse "$AUSPEX_VERIFY_EX_USAGE" "AUSPEX_BASE_URL must be an https URL, not '${AUSPEX_BASE_URL}'" ;;
    *) refuse "$AUSPEX_VERIFY_EX_USAGE" "set AUSPEX_BASE_URL to your auspex download host (https://…), from your install instructions" ;;
  esac

  prepare_state
  if ! acquire_lock; then
    result "another run is in progress; nothing to do"
    return 0
  fi
  trap cleanup EXIT

  provision_tool cosign
  provision_tool jq
  PATH="$STATE_DIR/bin:$PATH"

  local doc="$STATE_DIR/tmp/channels.json" installed decision action target
  read_channel "$doc"
  installed="$(installed_version)"
  case "$installed" in
    "" | [0-9]*.[0-9]*.[0-9]*) ;;
    *) refuse "$AUSPEX_VERIFY_EX_ENV" "can't read the installed auspex version from its package receipt ('${installed}')" ;;
  esac
  decision="$(decide "$doc" "$AUSPEX_CHANNEL" "$installed")" ||
    refuse "$AUSPEX_VERIFY_EX_ENV" "couldn't decide what to install from the channel document"
  action="${decision%% *}"
  target="${decision#* }"
  case "$action" in
    none) result "the ${AUSPEX_CHANNEL} channel names no release; nothing to do" ;;
    prerelease) refuse "$AUSPEX_UPDATE_EX_REFUSED" "the stable channel names a pre-release (${target}); refusing to install it" ;;
    below-minimum) refuse "$AUSPEX_UPDATE_EX_REFUSED" "the ${AUSPEX_CHANNEL} channel names ${target}, below the minimum; refusing to install it" ;;
    current) result "auspex ${target} is up to date with ${AUSPEX_CHANNEL}" ;;
    ahead) result "auspex v${installed} is ahead of ${AUSPEX_CHANNEL} (${target}); nothing to do" ;;
    install | upgrade)
      install_release "$target"
      result "installed auspex ${target} from ${AUSPEX_CHANNEL} (was ${installed:+v}${installed:-not installed})"
      ;;
    *) refuse "$AUSPEX_VERIFY_EX_ENV" "couldn't decide what to install from the channel document" ;;
  esac
}

if [ -z "${AUSPEX_UPDATE_NO_MAIN:-}" ]; then
  main
fi
