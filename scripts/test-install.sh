#!/usr/bin/env bash
# Tests install.sh paths that stop before touching the keychain or launchd.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0

# expect_failure <name> <expected output substring> <command...>
expect_failure() {
    local name="$1" expected="$2"
    shift 2
    local out status=0
    out="$("$@" 2>&1)" || status=$?
    if (( status == 0 )); then
        echo "FAIL $name: exited 0"
        failures=$((failures + 1))
    elif [[ "$out" != *"$expected"* ]]; then
        echo "FAIL $name: output does not contain '$expected':"
        printf '%s\n' "$out" | sed 's/^/    /'
        failures=$((failures + 1))
    else
        echo "ok   $name"
    fi
}

out="$(bash "$INSTALL" --help 2>&1)" || true
if [[ "$out" == *"Usage:"* ]]; then
    echo "ok   --help"
else
    echo "FAIL --help: no usage"
    failures=$((failures + 1))
fi

expect_failure "unknown option" "unknown option: --bogus" \
    bash "$INSTALL" --bogus
expect_failure "--app without path" "--app requires a path" \
    bash "$INSTALL" --app
expect_failure "--app missing path" "app not found: $TMP/nope.app" \
    bash "$INSTALL" --app "$TMP/nope.app"

mkdir -p "$TMP/Empty.app"
expect_failure "--app not a bundle" "not a MacInputSwitcher app bundle" \
    bash "$INSTALL" --app "$TMP/Empty.app"

# Fake release served over file:// whose checksum does not match.
mkdir -p "$TMP/release/latest/download"
echo "not a zip" > "$TMP/release/latest/download/MacInputSwitcher.zip"
echo "0000000000000000000000000000000000000000000000000000000000000000  MacInputSwitcher.zip" \
    > "$TMP/release/latest/download/MacInputSwitcher.zip.sha256"
expect_failure "checksum mismatch" "checksum mismatch for MacInputSwitcher.zip" \
    env BASE_URL="file://$TMP/release" bash "$INSTALL"

expect_failure "missing release" "failed to download" \
    env BASE_URL="file://$TMP/none" bash "$INSTALL"
expect_failure "pinned version uses its own URL" "download/v9.9.9/MacInputSwitcher.zip" \
    env BASE_URL="file://$TMP/release" VERSION=v9.9.9 bash "$INSTALL"

if (( failures > 0 )); then
    echo "$failures test(s) failed"
    exit 1
fi
echo "all tests passed"
