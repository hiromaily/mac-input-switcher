#!/usr/bin/env bash
# Installs, updates or uninstalls mac-input-switcher.
#
#   curl -fsSL https://raw.githubusercontent.com/hiromaily/mac-input-switcher/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/hiromaily/mac-input-switcher/main/install.sh | bash -s -- --uninstall
#
# Everything runs inside main(), invoked on the last line, so a truncated
# download never executes a partial script.
set -euo pipefail

REPO="hiromaily/mac-input-switcher"
APP_NAME="MacInputSwitcher"
EXEC_NAME="mac-input-switcher"
BUNDLE_ID="com.hiromaily.mac-input-switcher"
SIGN_IDENTITY="mac-input-switcher-local"
ASSET="$APP_NAME.zip"

INSTALLED_APP="$HOME/Applications/$APP_NAME.app"
AGENT_PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
LOG_FILE="$HOME/Library/Logs/$EXEC_NAME.log"
DOMAIN="gui/$(id -u)"

TMP=""
SOURCE_APP=""
STAGED_APP=""

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
cleanup() { if [[ -n "$TMP" ]]; then rm -rf "$TMP"; fi; }

usage() {
    cat <<EOU
Usage: install.sh [--app <path>] [--uninstall] [--help]

  (no option)     Install or update to the latest release
  --app <path>    Install a locally built $APP_NAME.app instead of downloading
  --uninstall     Remove the app, the LaunchAgent and its privacy permissions
  --help          Show this help

Environment:
  VERSION=v0.2.0  Install a specific release instead of the latest
EOU
}

preflight() {
    [[ "$(uname -s)" == "Darwin" ]] || die "macOS is required."
    local version major
    version="$(sw_vers -productVersion)"
    major="${version%%.*}"
    (( major >= 15 )) || die "macOS 15 or later is required (found $version)."
    [[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon (arm64) is required."
}

release_url() {
    local base="${BASE_URL:-https://github.com/$REPO/releases}"
    if [[ -n "${VERSION:-}" ]]; then
        printf '%s/download/%s/%s' "$base" "$VERSION" "$ASSET"
    else
        printf '%s/latest/download/%s' "$base" "$ASSET"
    fi
}

download_app() {
    local url
    url="$(release_url)"
    log "Downloading $url"
    curl -fsSL -o "$TMP/$ASSET" "$url" || die "failed to download $url"
    curl -fsSL -o "$TMP/$ASSET.sha256" "$url.sha256" || die "failed to download $url.sha256"

    log "Verifying checksum"
    (cd "$TMP" && shasum -a 256 -c "$ASSET.sha256" >/dev/null 2>&1) \
        || die "checksum mismatch for $ASSET"

    ditto -x -k "$TMP/$ASSET" "$TMP/unzipped" || die "failed to extract $ASSET"
    SOURCE_APP="$TMP/unzipped/$APP_NAME.app"
}

has_identity() {
    security find-identity -v -p codesigning | grep -q "\"$SIGN_IDENTITY\""
}

# Creates a self-signed code signing identity in the login keychain so that
# every installed build keeps the same designated requirement, and therefore
# the Input Monitoring / Accessibility permissions survive updates.
ensure_identity() {
    if has_identity; then
        return
    fi

    # Remove leftovers from an earlier run whose trust step was cancelled.
    while security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; do
        security delete-identity -c "$SIGN_IDENTITY" >/dev/null 2>&1 \
            || security delete-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1 \
            || break
    done

    log "Creating code signing identity '$SIGN_IDENTITY'"
    log "macOS will ask for your login password to trust it (first install only)"

    local keychain="$HOME/Library/Keychains/login.keychain-db"
    cat > "$TMP/cert.cnf" <<EOC
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $SIGN_IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOC

    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" >/dev/null 2>&1 \
        || die "failed to generate the signing certificate"
    /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -name "$SIGN_IDENTITY" -passout pass:temp -out "$TMP/identity.p12" >/dev/null 2>&1 \
        || die "failed to package the signing certificate"

    security import "$TMP/identity.p12" -k "$keychain" -P temp -T /usr/bin/codesign >/dev/null \
        || die "failed to import the signing certificate into the login keychain"
    security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$TMP/cert.pem" \
        || die "the certificate was not trusted (password dialog cancelled?). Run the installer again."

    has_identity || die "signing identity '$SIGN_IDENTITY' is not usable"
}

stage_app() {
    [[ -x "$SOURCE_APP/Contents/MacOS/$EXEC_NAME" ]] \
        || die "not a $APP_NAME app bundle: $SOURCE_APP"
    mkdir -p "$TMP/stage"
    STAGED_APP="$TMP/stage/$APP_NAME.app"
    ditto "$SOURCE_APP" "$STAGED_APP"
}

sign_app() {
    log "Signing with '$SIGN_IDENTITY'"
    codesign --force --options runtime --sign "$SIGN_IDENTITY" "$STAGED_APP" \
        || die "codesign failed"
    codesign --verify --strict "$STAGED_APP" || die "signature verification failed"
}

stop_agent() {
    launchctl bootout "$DOMAIN/$BUNDLE_ID" >/dev/null 2>&1 || true
    # bootout returns before the job is fully removed; bootstrap fails until it is.
    for _ in $(seq 1 50); do
        launchctl print "$DOMAIN/$BUNDLE_ID" >/dev/null 2>&1 || return 0
        sleep 0.1
    done
    die "the running agent did not stop"
}

write_plist() {
    cat > "$AGENT_PLIST" <<EOP
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$BUNDLE_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALLED_APP/Contents/MacOS/$EXEC_NAME</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$LOG_FILE</string>
    <key>StandardErrorPath</key>
    <string>$LOG_FILE</string>
</dict>
</plist>
EOP
}

install_app() {
    log "Installing to $INSTALLED_APP"
    stop_agent
    mkdir -p "$(dirname "$INSTALLED_APP")" "$(dirname "$AGENT_PLIST")" "$(dirname "$LOG_FILE")"
    rm -rf "$INSTALLED_APP"
    ditto "$STAGED_APP" "$INSTALLED_APP"
    write_plist
    launchctl bootstrap "$DOMAIN" "$AGENT_PLIST" || die "failed to start the LaunchAgent"
}

print_next_steps() {
    cat <<EON

Installed $APP_NAME.

If macOS asks, allow $APP_NAME in System Settings > Privacy & Security under
both "Input Monitoring" and "Accessibility". It starts working as soon as both
are granted (no restart needed).

  Logs:      tail -f $LOG_FILE
  Update:    run the same install command again
  Uninstall: curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash -s -- --uninstall
EON
}

uninstall() {
    log "Uninstalling $APP_NAME"
    launchctl bootout "$DOMAIN/$BUNDLE_ID" >/dev/null 2>&1 || true
    rm -f "$AGENT_PLIST"
    rm -rf "$INSTALLED_APP"
    local service
    for service in ListenEvent Accessibility PostEvent; do
        tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1 || true
    done
    cat <<EOU
Uninstalled. The signing certificate '$SIGN_IDENTITY' was kept in your login keychain.
To remove it as well:
  security delete-identity -c $SIGN_IDENTITY
EOU
}

main() {
    local app_arg="" mode="install"
    while (( $# > 0 )); do
        case "$1" in
            --app)
                [[ $# -ge 2 ]] || die "--app requires a path"
                app_arg="$2"
                shift 2
                ;;
            --uninstall)
                mode="uninstall"
                shift
                ;;
            -h | --help)
                usage
                return 0
                ;;
            *)
                usage >&2
                die "unknown option: $1"
                ;;
        esac
    done

    if [[ "$mode" == "uninstall" ]]; then
        uninstall
        return 0
    fi

    preflight
    TMP="$(mktemp -d)"
    trap cleanup EXIT

    if [[ -n "$app_arg" ]]; then
        [[ -d "$app_arg" ]] || die "app not found: $app_arg"
        SOURCE_APP="$app_arg"
    else
        download_app
    fi

    stage_app
    ensure_identity
    sign_app
    install_app
    print_next_steps
}

main "$@"
