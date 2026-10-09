# インストーラー Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 一般ユーザーが `curl -fsSL .../install.sh | bash` の 1 行で、Gatekeeper の警告なしにインストール・アップデート・アンインストールできるようにする。

**Architecture:** タグ push で GitHub Actions が ad-hoc 署名の `.app` を zip にし、sha256 と一緒に Releases へ上げる。単体で完結する `install.sh` がそれを取得・検証し、ユーザーの Mac 上の自己署名証明書 `mac-input-switcher-local` で再署名して `~/Applications` に配置、LaunchAgent を登録する。`make install` / `make uninstall` も `install.sh` に委譲し、インストール処理を一本化する。

**Tech Stack:** bash、curl、shasum、ditto、codesign、security、openssl（/usr/bin, LibreSSL）、launchctl、tccutil、make、GitHub Actions（macos-15）、shellcheck

**Spec:** `docs/superpowers/specs/2026-10-09-installer-design.md`

## Global Constraints

- 対象: macOS 15 以降 / Apple Silicon（arm64）のみ
- Bundle ID / LaunchAgent Label: `com.hiromaily.mac-input-switcher`
- アプリ名: `MacInputSwitcher.app`、実行ファイル名: `mac-input-switcher`
- 署名 ID: `mac-input-switcher-local`（既存の `make install` 利用者と同じ名前で互換を保つ）
- インストール先: `~/Applications/MacInputSwitcher.app`
- LaunchAgent: `~/Library/LaunchAgents/com.hiromaily.mac-input-switcher.plist`、`RunAtLoad=true`, `KeepAlive=true`, `ThrottleInterval=10`, `ProcessType=Interactive`
- ログ: `~/Library/Logs/mac-input-switcher.log`
- リリース資産名: `MacInputSwitcher.zip` と `MacInputSwitcher.zip.sha256`（中身は `<hash>  MacInputSwitcher.zip`）
- install.sh は `curl | bash` で動くこと: 単体で完結し、stdin を読まず、全処理を `main "$@"` で最後に呼ぶ
- アンインストール時に TCC エントリ（ListenEvent / Accessibility / PostEvent）を削除する。署名用証明書は削除しない
- 作業ブランチ: `feature/installer`（PR で main にマージ）

## Review Focus

1. **`curl | bash` の途中でダウンロードが切れる** → 途中までのスクリプトが実行されないこと（全処理を関数に入れ、最終行の `main "$@"` でのみ起動する。Task 1 のコード構造で担保し、レビューで確認する）
2. **証明書を信頼するときのパスワードダイアログをキャンセルした** → 分かるエラーで止まり、再実行すれば信頼されていない証明書の残骸を消して作り直せること（Task 1 `ensure_identity`。手動テストは Task 2 Step 6）
3. **sha256 が一致しない / リリースが存在しない / 指定バージョンが存在しない** → キーチェーンや launchd に触れる前に非 0 で止まること（Task 1 `scripts/test-install.sh`）
4. **常駐中に再インストールする** → 旧プロセスが確実に止まってから bootstrap し、`Bootstrap failed: 5` にならないこと（Task 1 `install_app` の待機ループ。手動テストは Task 2 Step 5）
5. **`--app` に存在しないパスや .app でないディレクトリを渡す** → 何も変更せずにエラーで止まること（Task 1 `scripts/test-install.sh`）

---

### Task 1: install.sh と、その失敗系テスト

**Files:**
- Create: `scripts/test-install.sh`
- Create: `install.sh`

**Interfaces:**
- Consumes: なし
- Produces:
  - `install.sh [--app <path>] [--uninstall] [--help]`
  - 環境変数 `VERSION`（例 `v0.2.0`、リリースを固定する）と `BASE_URL`（テスト用。既定値は `https://github.com/hiromaily/mac-input-switcher/releases`）
  - エラーメッセージ（テストが部分一致で検証する）:
    - `unknown option: <opt>`
    - `--app requires a path`
    - `app not found: <path>`
    - `not a MacInputSwitcher app bundle: <path>`
    - `failed to download <url>`
    - `checksum mismatch for MacInputSwitcher.zip`
  - `scripts/test-install.sh`: 全部通れば exit 0。Task 2 で `make test` から、Task 3 で CI から呼ぶ

- [ ] **Step 1: 失敗系テストを書く**

`scripts/test-install.sh` を作成する。ここでテストするのは、キーチェーンや launchd に触れる前に止まる経路だけにする。

```bash
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

out="$(bash "$INSTALL" --help)"
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
```

実行権限を付ける: `chmod +x scripts/test-install.sh`

- [ ] **Step 2: テストが失敗することを確認する**

Run: `scripts/test-install.sh`
Expected: `install.sh` がまだ無いため、`--help` 以降がすべて FAIL になり、exit 1 で終わる

- [ ] **Step 3: install.sh を実装する**

リポジトリ直下に `install.sh` を作成する。証明書作成の処理は現行の `scripts/create-signing-cert.sh` から移植したもので、そのファイルは Task 2 で削除する。

```bash
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
```

実行権限を付ける: `chmod +x install.sh`

- [ ] **Step 4: テストが通ることを確認する**

Run: `scripts/test-install.sh`
Expected: 8 行すべて `ok`、最後に `all tests passed`、exit 0

- [ ] **Step 5: shellcheck をかける**

ローカルに shellcheck が無ければ、利用者に `brew install shellcheck` の実行可否を確認してから入れる。

Run: `shellcheck install.sh scripts/test-install.sh`
Expected: 出力なし、exit 0。警告が出たら修正し、Step 4 を再実行する。

- [ ] **Step 6: コミットする**

```bash
git add install.sh scripts/test-install.sh
git commit -m "feat: add standalone install.sh for curl | bash installs"
```

---

### Task 2: Makefile と Info.plist を install.sh に寄せ、旧ファイルを削除する

**Files:**
- Modify: `Makefile`（全体を置き換える）
- Modify: `Resources/Info.plist`（`CFBundleShortVersionString`）
- Delete: `scripts/create-signing-cert.sh`
- Delete: `LaunchAgent/com.hiromaily.mac-input-switcher.plist`

**Interfaces:**
- Consumes: Task 1 の `install.sh --app <path>`、`install.sh --uninstall`、`scripts/test-install.sh`
- Produces: `make build VERSION=<x.y.z>`（`build/MacInputSwitcher.app` を生成し、Info.plist にバージョンを埋め込む）、`make test`（swift test と scripts/test-install.sh を実行）。どちらも Task 3 の CI が使う

- [ ] **Step 1: Info.plist のバージョンをテンプレート化する**

`Resources/Info.plist` の該当行を変更する:

```xml
    <key>CFBundleShortVersionString</key>
    <string>__VERSION__</string>
```

- [ ] **Step 2: Makefile を置き換える**

```make
APP_NAME      := MacInputSwitcher
EXEC_NAME     := mac-input-switcher
BUNDLE_ID     := com.hiromaily.mac-input-switcher
VERSION       ?= 0.0.0-dev

APP           := build/$(APP_NAME).app
LOG_FILE      := $(HOME)/Library/Logs/$(EXEC_NAME).log

.PHONY: test build install uninstall logs clean

test:
	swift test
	scripts/test-install.sh

build:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	sed -e "s|__BUNDLE_ID__|$(BUNDLE_ID)|" \
	    -e "s|__VERSION__|$(VERSION)|" \
	    Resources/Info.plist > $(APP)/Contents/Info.plist
	cp .build/release/$(EXEC_NAME) $(APP)/Contents/MacOS/$(EXEC_NAME)

install: build
	./install.sh --app $(APP)

uninstall:
	./install.sh --uninstall

logs:
	tail -f $(LOG_FILE)

clean:
	rm -rf .build build
```

- [ ] **Step 3: 旧ファイルを削除する**

```bash
git rm scripts/create-signing-cert.sh LaunchAgent/com.hiromaily.mac-input-switcher.plist
```

- [ ] **Step 4: ビルドとテストを確認する**

Run: `make test && make build VERSION=1.2.3 && /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/MacInputSwitcher.app/Contents/Info.plist`
Expected: swift test が全件成功し、`all tests passed` と `1.2.3` が表示される

- [ ] **Step 5: `make install` で実機インストールを確認する（Review Focus 4）**

作業者のマシンに常駐中のインストールを置き換える操作なので、実行前に利用者の了承を得る。

Run: `make install && sleep 3 && launchctl print gui/$(id -u)/com.hiromaily.mac-input-switcher | grep -E 'state|program' && tail -n 5 ~/Library/Logs/mac-input-switcher.log`
Expected:
- 常駐中に実行しても `Bootstrap failed` が出ず、`Installed MacInputSwitcher.` が表示される
- `state = running` になる
- 既存の証明書を使い回すので権限ダイアログが出ず、ログに `mac-input-switcher started` が出る

続けて、利用者に左右の⌘を単独で押して入力が切り替わることを確認してもらう。

- [ ] **Step 6: 証明書作成と、キャンセルからの復帰を確認する（Review Focus 2、任意）**

ログインキーチェーンを変更する操作なので、利用者の了承を得た場合だけ実施する。了承がなければスキップし、その旨を報告する。

1. `security delete-identity -c mac-input-switcher-local` を実行する
2. `make install` を実行し、パスワードダイアログで「キャンセル」を押す
   - Expected: `the certificate was not trusted (password dialog cancelled?). Run the installer again.` で止まる
3. もう一度 `make install` を実行し、今度はパスワードを入れる
   - Expected: 残骸が消されて証明書が作り直され、インストールが完了する
4. 署名 ID が変わったので、権限は付け直しが必要になる。権限一覧から旧エントリを削除し、改めて許可する

- [ ] **Step 7: コミットする**

```bash
git add Makefile Resources/Info.plist
git commit -m "build: delegate make install/uninstall to install.sh and stamp version"
```

---

### Task 3: リリース用 GitHub Actions ワークフロー

**Files:**
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: Task 2 の `make test`、`make build VERSION=<x.y.z>`。Task 1 の `install.sh` と `scripts/test-install.sh`（shellcheck の対象）
- Produces: `v*` タグの Release に `MacInputSwitcher.zip` と `MacInputSwitcher.zip.sha256` を添付する。Task 1 の `install.sh` が既定の URL でこれを取得する

- [ ] **Step 1: ワークフローを書く**

```yaml
name: release

on:
  push:
    tags: ['v*']

permissions:
  contents: write

jobs:
  release:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4

      - name: Lint installer
        run: |
          brew install shellcheck
          shellcheck install.sh scripts/test-install.sh

      - name: Test
        run: make test

      - name: Build
        run: make build VERSION="${GITHUB_REF_NAME#v}"

      - name: Package
        run: |
          codesign --force --sign - build/MacInputSwitcher.app
          ditto -c -k --keepParent build/MacInputSwitcher.app MacInputSwitcher.zip
          shasum -a 256 MacInputSwitcher.zip > MacInputSwitcher.zip.sha256

      - name: Publish
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release create "$GITHUB_REF_NAME" \
            MacInputSwitcher.zip MacInputSwitcher.zip.sha256 \
            --generate-notes
```

- [ ] **Step 2: パッケージ手順をローカルで再現する**

CI と同じコマンドで zip と sha256 を作り、`file://` 経由で install.sh が checksum を通過することを確認する。キーチェーンや launchd に触れないよう、展開の直後で止める。

```bash
SCRATCH="$(mktemp -d)"
make build VERSION=0.0.0-local
codesign --force --sign - build/MacInputSwitcher.app
mkdir -p "$SCRATCH/latest/download"
ditto -c -k --keepParent build/MacInputSwitcher.app "$SCRATCH/latest/download/MacInputSwitcher.zip"
(cd "$SCRATCH/latest/download" && shasum -a 256 MacInputSwitcher.zip > MacInputSwitcher.zip.sha256)
(cd "$SCRATCH/latest/download" && shasum -a 256 -c MacInputSwitcher.zip.sha256)
ditto -x -k "$SCRATCH/latest/download/MacInputSwitcher.zip" "$SCRATCH/unzipped"
test -x "$SCRATCH/unzipped/MacInputSwitcher.app/Contents/MacOS/mac-input-switcher" && echo "bundle ok"
rm -rf "$SCRATCH"
```

Expected: `MacInputSwitcher.zip: OK` と `bundle ok`。これで、sha256 ファイルの形式が install.sh の `shasum -c` と、zip の中身の構成が `stage_app` の検査と一致していることを確かめる。

- [ ] **Step 3: ワークフローの構文を確認する**

`actionlint` があれば `actionlint .github/workflows/release.yml` を実行する。無ければ `ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml")' && echo yaml ok` で YAML として読めることだけを確認する。

Expected: エラーなし

- [ ] **Step 4: コミットする**

```bash
git add .github/workflows/release.yml
git commit -m "ci: build and publish release zip on version tags"
```

---

### Task 4: README を一般ユーザー向けに書き直す

**Files:**
- Modify: `README.md`（全体を置き換える）

**Interfaces:**
- Consumes: Task 1 の install.sh の使い方、Task 2 の make ターゲット、Task 3 のリリース手順
- Produces: なし

- [ ] **Step 1: README.md を置き換える**

````markdown
# mac-input-switcher

US キーボードで **左⌘単独押し → 英語入力 / 右⌘単独押し → 日本語入力** に切り替える macOS 常駐ツール。
Karabiner-Elements のような仮想ドライバーを使わず、macOS 標準 API（CGEventTap）のみで動作します。

## 動作条件

- macOS 15 以降 / Apple Silicon
- 入力ソースに「ABC」と「日本語 - ローマ字入力」を追加済み

## インストール

ターミナルで次を実行します。

```sh
curl -fsSL https://raw.githubusercontent.com/hiromaily/mac-input-switcher/main/install.sh | bash
```

1. 初回のみ、ログインパスワードを求めるダイアログが出ます。インストーラーがこの Mac 専用の署名用証明書を作り、キーチェーンで信頼するためです。これで、アップデートしても下記の許可が外れなくなります。
2. 許可を求めるダイアログが出たら、システム設定 > プライバシーとセキュリティ で **入力監視** と **アクセシビリティ** に `MacInputSwitcher` を許可します。許可されると、再起動なしで動き出します。

特定のバージョンを入れる場合:

```sh
curl -fsSL https://raw.githubusercontent.com/hiromaily/mac-input-switcher/main/install.sh | VERSION=v0.2.0 bash
```

## アップデート

インストールと同じコマンドをもう一度実行します。許可はそのまま引き継がれます。

## アンインストール

```sh
curl -fsSL https://raw.githubusercontent.com/hiromaily/mac-input-switcher/main/install.sh | bash -s -- --uninstall
```

アプリ、自動起動の設定、入力監視・アクセシビリティの許可を削除します。署名用証明書はキーチェーンに残ります。不要なら `security delete-identity -c mac-input-switcher-local` で削除できます。

## 使い方

| 操作 | 結果 |
|---|---|
| 左⌘を単独で押して離す（0.5 秒以内） | 英語入力 |
| 右⌘を単独で押して離す（0.5 秒以内） | 日本語入力 |
| ⌘+キー、⌘+クリック、長押し | 切り替えない（通常の⌘として動作） |

パスワード入力欄など Secure Input 中は、macOS の制約で動作しません。

## トラブルシュート

- 動かない: `tail -f ~/Library/Logs/mac-input-switcher.log` で `waiting for permissions` が出ていないか確認し、権限を付け直してください。許可されれば再起動なしで動き出します
- 権限一覧に古いエントリが残る: 一度削除してから、インストールのコマンドを再実行してください
- 「the certificate was not trusted」で止まった: パスワードダイアログをキャンセルした場合に出ます。もう一度インストールのコマンドを実行してください
- 許可ダイアログが閉じられない: `killall universalAccessAuthWarn` で閉じられます（必要時に macOS が再起動します）

## 開発

Command Line Tools（`xcode-select --install`）が必要です。

```sh
make test        # ユニットテストと install.sh のテスト
make install     # ビルドして install.sh --app 経由でインストール（権限は維持されます）
make uninstall   # アンインストール（権限エントリも削除されます）
make logs        # ログを表示
```

`.build/release/mac-input-switcher` をターミナルから直接実行すると、権限の要求元がターミナルアプリになります。常駐は `make install` 経由で行ってください。

### リリース

```sh
git tag v0.2.0
git push origin v0.2.0
```

GitHub Actions がテスト・ビルドを行い、`MacInputSwitcher.zip` とその sha256 を Releases に公開します。`install.sh` は、既定で最新リリースを取得します。

### 手動テスト

1. テキストエディタで左⌘単独押し → 英語、右⌘単独押し → 日本語に切り替わる
2. ⌘C / ⌘V / ⌘Tab / ⌘+クリックで入力モードが変わらない
3. インストールコマンドを再実行しても、権限ダイアログが出ずに動作する
4. `launchctl kill TERM gui/$(id -u)/com.hiromaily.mac-input-switcher` の後、数秒で自動復帰する（ログで `started` を確認）
5. アンインストール後、システム設定の権限一覧から `MacInputSwitcher` が消えている
````

- [ ] **Step 2: 古い参照が残っていないか確認する**

Run: `grep -rn "create-signing-cert\|LaunchAgent/com\|make sign" --exclude-dir=.build --exclude-dir=docs .`
Expected: ヒットなし。過去の spec / plan は作業記録なので対象外とする。

- [ ] **Step 3: コミットする**

```bash
git add README.md
git commit -m "docs: document curl installer, update and uninstall"
```

---

## マージ後の確認（利用者が実施）

タグの push は外部に公開する操作なので、PR をマージしたあと利用者自身が行う。

1. `git tag v0.2.0 && git push origin v0.2.0` を実行し、Actions が成功して Release に 2 つのファイルが付くことを確認する
2. `make uninstall` のあと、README のインストールコマンドで入れ直し、権限を許可すると動作することを確認する
3. 同じコマンドを再実行して、権限ダイアログが出ないことを確認する
4. アンインストールのコマンドを実行し、権限一覧からエントリが消えることを確認する
