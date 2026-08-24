#!/usr/bin/env bash
set -euo pipefail

# Validates the root CHANGELOG.md — the durable "what changed" for the things
# customers install from this repo (the span-auspex Dev Container Feature and the
# installer scripts).
#
# This repo is PUBLIC, so the guard is deliberately LIGHT — a structural check
# only. Unlike the private auspex repo's changelog guard, it does NOT carry a
# public-safety leak-check (there is no private->public boundary to protect here)
# and there is NO release tag-gate (this repo has no single-SemVer release
# pipeline; the Feature and the installers version independently). What it checks:
#
# 1. An "## [Unreleased]" section exists and is the first version heading.
# 2. Every "## [...]" heading is either "[Unreleased]" or a date "[YYYY-MM-DD]"
#    (a free-form label after the bracket is allowed).
# 3. Dates are ISO-8601 (YYYY-MM-DD), in-range, and not in the future.
# 4. Dated sections use unique dates in strictly descending order (newest first).
# 5. Every dated section is non-empty (at least one "- " bullet).
# 6. Every "### <Category>" is one of the fixed Keep a Changelog categories.
#
# Usage:
#   validate-changelog.sh [<changelog-path>]   validate a file (default: repo-root CHANGELOG.md)
#   validate-changelog.sh --self-test          prove the guard bites on bad fixtures
#
# Exit code 0 = all checks pass, 1 = validation errors, 2 = usage error.

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ALLOWED_CATEGORIES="Added Changed Fixed Security Removed Deprecated"

# ---------------------------------------------------------------------------
# validate <changelog-path> : run the structural checks, print + count errors.
# Returns non-zero if any check failed.
# ---------------------------------------------------------------------------
validate() {
    local changelog="$1"
    local errors=0
    local today
    today="$(date +%F)"

    _err() {
        echo "ERROR: $1"
        errors=$((errors + 1))
    }

    if [ ! -f "$changelog" ]; then
        echo "ERROR: changelog not found at $changelog"
        return 1
    fi

    # Collect the "## [...]" version headings in order of appearance.
    # (avoid `mapfile` — macOS ships bash 3.2, which lacks it.)
    local headings=()
    local ln
    while IFS= read -r ln; do
        [ -z "$ln" ] && continue
        headings+=("$ln")
    done < <(grep -nE '^## \[' "$changelog" || true)

    if [ ${#headings[@]} -eq 0 ]; then
        _err "no '## [Unreleased]' or '## [YYYY-MM-DD]' version headings found."
    fi

    local dates=()
    local first_heading=true
    local entry line date month day
    for entry in ${headings[@]+"${headings[@]}"}; do
        line="${entry#*:}" # strip "<lineno>:"

        if [[ "$line" =~ ^##\ \[Unreleased\][[:space:]]*$ ]]; then
            if [ "$first_heading" != true ]; then
                _err "'## [Unreleased]' must be the first version heading."
            fi
            first_heading=false
            continue
        fi

        if [ "$first_heading" = true ]; then
            _err "the first version heading must be '## [Unreleased]', found: $line"
            first_heading=false
        fi

        # "## [YYYY-MM-DD]" with an optional free-form label after the bracket.
        if [[ "$line" =~ ^##\ \[([0-9]{4}-[0-9]{2}-[0-9]{2})\]([[:space:]].*)?$ ]]; then
            date="${BASH_REMATCH[1]}"
            dates+=("$date")

            month="${date:5:2}"
            day="${date:8:2}"
            if [ "$((10#$month))" -lt 1 ] || [ "$((10#$month))" -gt 12 ] ||
                [ "$((10#$day))" -lt 1 ] || [ "$((10#$day))" -gt 31 ]; then
                _err "section [$date] has an out-of-range date."
            fi
            if [[ "$date" > "$today" ]]; then
                _err "section [$date] is dated in the future ($date > $today)."
            fi

            # Section body must be non-empty (at least one bullet before the next "## ").
            # Match on a literal heading prefix, not a regex — macOS awk lacks `{n}`.
            local body
            body="$(awk -v pfx="## [$date]" '
                index($0, pfx) == 1 {inbody = 1; next}
                inbody && substr($0, 1, 3) == "## " {exit}
                inbody {print}
            ' "$changelog")"
            if ! grep -qE '^- ' <<< "$body"; then
                _err "section '## [$date]' is empty — a dated section must carry at least one note."
            fi
        else
            _err "malformed version heading (expected '## [Unreleased]' or '## [YYYY-MM-DD]'): $line"
        fi
    done

    if ! grep -qE '^## \[Unreleased\][[:space:]]*$' "$changelog"; then
        _err "missing required '## [Unreleased]' section."
    fi

    # Dated sections: unique + strictly descending (ISO dates sort chronologically).
    if [ ${#dates[@]} -gt 0 ]; then
        local dups
        dups="$(printf '%s\n' "${dates[@]}" | sort | uniq -d)"
        if [ -n "$dups" ]; then
            _err "duplicate dated section(s) — fold same-day changes into one section: $(echo "$dups" | paste -sd' ' -)"
        fi
        local as_written descending
        as_written="$(printf '%s\n' "${dates[@]}")"
        descending="$(printf '%s\n' "${dates[@]}" | sort -r)"
        if [ "$as_written" != "$descending" ]; then
            _err "dated sections must be in descending order (newest first). Found: $(printf '%s ' "${dates[@]}")"
        fi
    fi

    # Category headings must be from the fixed set.
    local cat_line cat
    while IFS= read -r cat_line; do
        [ -z "$cat_line" ] && continue
        cat="${cat_line#\#\#\# }"
        cat="${cat%"${cat##*[![:space:]]}"}" # rstrip
        if ! grep -qwF "$cat" <<< "$ALLOWED_CATEGORIES"; then
            _err "unknown category '### $cat' (allowed: $ALLOWED_CATEGORIES)."
        fi
    done < <(grep -E '^### ' "$changelog" || true)

    if [ "$errors" -gt 0 ]; then
        echo ""
        echo "Changelog validation failed with $errors error(s)."
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# --self-test : fabricate bad fixtures, assert each FAILS, and a clean one PASSES.
# Mirrors auspex's prove-it-bites meta-tests: a guard that never fails is worthless.
# ---------------------------------------------------------------------------
self_test() {
    local tmp failures=0
    tmp="$(mktemp -d)"

    _expect_fail() {
        local name="$1" file="$2"
        if validate "$file" >/dev/null 2>&1; then
            echo "SELF-TEST FAIL: '$name' should have been rejected but passed."
            failures=$((failures + 1))
        else
            echo "  ok (bites): $name"
        fi
    }
    _expect_pass() {
        local name="$1" file="$2"
        if validate "$file" >/dev/null 2>&1; then
            echo "  ok (passes): $name"
        else
            echo "SELF-TEST FAIL: '$name' should have passed but was rejected."
            failures=$((failures + 1))
        fi
    }

    printf '# Changelog\n\n## [2026-08-19]\n\n### Added\n\n- a note\n' > "$tmp/no-unreleased.md"
    _expect_fail "missing [Unreleased]" "$tmp/no-unreleased.md"

    printf '# Changelog\n\n## [Unreleased]\n\n## [19-08-2026]\n\n### Added\n\n- a note\n' > "$tmp/bad-date.md"
    _expect_fail "non-ISO date heading" "$tmp/bad-date.md"

    printf '# Changelog\n\n## [Unreleased]\n\n## [2099-01-01]\n\n### Added\n\n- a note\n' > "$tmp/future.md"
    _expect_fail "future-dated section" "$tmp/future.md"

    printf '# Changelog\n\n## [Unreleased]\n\n## [2026-08-10]\n\n### Added\n\n- older\n\n## [2026-08-19]\n\n### Added\n\n- newer\n' > "$tmp/ascending.md"
    _expect_fail "ascending (oldest-first) order" "$tmp/ascending.md"

    printf '# Changelog\n\n## [Unreleased]\n\n## [2026-08-19]\n\n### Added\n\n- a note\n\n## [2026-08-19]\n\n### Fixed\n\n- dup\n' > "$tmp/dup.md"
    _expect_fail "duplicate dated sections" "$tmp/dup.md"

    printf '# Changelog\n\n## [Unreleased]\n\n## [2026-08-19]\n\n### Newsflash\n\n- a note\n' > "$tmp/bad-cat.md"
    _expect_fail "unknown category" "$tmp/bad-cat.md"

    printf '# Changelog\n\n## [Unreleased]\n\n## [2026-08-19]\n\n### Added\n' > "$tmp/empty.md"
    _expect_fail "empty dated section" "$tmp/empty.md"

    printf '# Changelog\n\n## [Unreleased]\n\n## [2026-08-19] - Initial release\n\n### Added\n\n- a note about **Feature 0.3.0**\n' > "$tmp/clean.md"
    _expect_pass "clean changelog (with a date label)" "$tmp/clean.md"

    rm -rf "$tmp"

    echo ""
    if [ "$failures" -gt 0 ]; then
        echo "Self-test FAILED with $failures problem(s)."
        return 1
    fi
    echo "Self-test passed: the guard bites on every bad fixture and accepts a clean one."
    return 0
}

# ---------------------------------------------------------------------------
main() {
    case "${1:-}" in
        --self-test)
            self_test
            ;;
        -h | --help)
            echo "usage: validate-changelog.sh [<changelog-path>] | --self-test"
            exit 0
            ;;
        "")
            echo "==> Validating CHANGELOG.md structure..."
            validate "$REPO_ROOT/CHANGELOG.md"
            echo ""
            echo "All changelog validation checks passed."
            ;;
        *)
            validate "$1"
            ;;
    esac
}

main "$@"
