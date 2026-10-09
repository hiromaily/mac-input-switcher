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

# The following tests run install.sh against stubbed system commands and a
# throwaway HOME, so the real keychain, launchd and TCC are never touched.
STUBS="$TMP/bin"
CALLS="$TMP/calls.log"
mkdir -p "$STUBS"
cat > "$STUBS/launchctl" <<'EOS'
#!/usr/bin/env bash
echo "launchctl $*" >> "$CALLS"
[[ "$1" != "print" ]]
EOS
cat > "$STUBS/tccutil" <<'EOS'
#!/usr/bin/env bash
if [[ -d "$HOME/Applications/MacInputSwitcher.app" ]]; then present=yes; else present=no; fi
echo "tccutil $* app_present=$present" >> "$CALLS"
EOS
cat > "$STUBS/codesign" <<'EOS'
#!/usr/bin/env bash
echo "codesign $*" >> "$CALLS"
EOS
# Lists the identity first, then enough other identities to overflow a pipe
# buffer, as on a developer Mac with many signing identities.
cat > "$STUBS/security" <<'EOS'
#!/usr/bin/env bash
echo "security $1" >> "$CALLS"
if [[ "$1" == "find-identity" ]]; then
    echo '  1) 0123456789ABCDEF "mac-input-switcher-local"'
    for i in $(seq 1 20000); do echo "  $i) FEDCBA9876543210 \"Apple Development: someone ($i)\""; done
fi
# The certificate disappears once deleted, so the cleanup loop ends.
if [[ "$1" == "find-certificate" ]] && grep -q "^security delete-identity" "$CALLS"; then
    exit 1
fi
EOS
cat > "$STUBS/id" <<'EOS'
#!/usr/bin/env bash
if [[ "$1" == "-u" && -n "${FAKE_UID:-}" ]]; then echo "$FAKE_UID"; else exec /usr/bin/id "$@"; fi
EOS
chmod +x "$STUBS"/*

# run_stubbed <home> <install.sh args...>
run_stubbed() {
    local home="$1"
    shift
    : > "$CALLS"
    mkdir -p "$home"
    env HOME="$home" PATH="$STUBS:$PATH" CALLS="$CALLS" bash "$INSTALL" "$@" >/dev/null 2>&1
}

# expect_calls <name> <grep -E pattern> <present|absent>
expect_calls() {
    local name="$1" pattern="$2" want="$3"
    if grep -Eq "$pattern" "$CALLS"; then got=present; else got=absent; fi
    if [[ "$got" == "$want" ]]; then
        echo "ok   $name"
    else
        echo "FAIL $name: '$pattern' expected $want in calls:"
        sed 's/^/    /' "$CALLS"
        failures=$((failures + 1))
    fi
}

home="$TMP/home-uninstall"
mkdir -p "$home/Applications/MacInputSwitcher.app" "$home/Library/LaunchAgents"
run_stubbed "$home" --uninstall || true
expect_calls "uninstall resets TCC while the app is still registered" \
    "^tccutil reset ListenEvent .* app_present=yes" present

mkdir -p "$TMP/Fake.app/Contents/MacOS"
printf '#!/bin/sh\n' > "$TMP/Fake.app/Contents/MacOS/mac-input-switcher"
chmod +x "$TMP/Fake.app/Contents/MacOS/mac-input-switcher"
run_stubbed "$TMP/home-identity" --app "$TMP/Fake.app" || true
expect_calls "existing identity is kept with many identities listed" \
    "^security (delete-identity|import)" absent

expect_failure "refuses to install as root" "do not run as root" \
    env FAKE_UID=0 HOME="$TMP/home-root" PATH="$STUBS:$PATH" CALLS="$CALLS" bash "$INSTALL" --app "$TMP/Fake.app"
expect_failure "refuses to uninstall as root" "do not run as root" \
    env FAKE_UID=0 HOME="$TMP/home-root" PATH="$STUBS:$PATH" CALLS="$CALLS" bash "$INSTALL" --uninstall

if (( failures > 0 )); then
    echo "$failures test(s) failed"
    exit 1
fi
echo "all tests passed"
