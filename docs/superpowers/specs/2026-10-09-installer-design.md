# インストーラー 設計

- 日付: 2026-10-09
- ステータス: レビュー待ち

## 背景と目的

基本機能の実装が終わったので、一般ユーザーが clone・ビルドせずに導入できるようにしたい。
配布先は不特定の一般ユーザー（GitHub Releases で公開）。Apple Developer Program には加入しない。

## 制約

- Developer ID 署名・公証ができない。ブラウザでダウンロードしたファイルは quarantine 属性が付き、Gatekeeper にブロックされる。`curl` で取得したファイルには付かない
- 入力監視・アクセシビリティの許可（TCC）は署名の designated requirement に紐づく。ad-hoc 署名では cdhash がビルドごとに変わり、更新のたびに権限が外れる
- ユーザーの Mac 上で作った自己署名証明書で再署名すれば、designated requirement が固定され、更新後も権限が維持される

## 要件

- ターミナルで 1 行実行するだけでインストールできる。Xcode / Command Line Tools は不要
- Gatekeeper の警告が出ない
- 同じコマンドの再実行でアップデートでき、権限が維持される
- アンインストールで、ファイル・LaunchAgent・TCC の権限エントリを削除する
- リリースはタグの push で自動生成する
- 対象は macOS 15 以降 / Apple Silicon（arm64）のみ

## 非要件（YAGNI）

- .pkg / .dmg インストーラー
- Homebrew tap（必要になれば、install.sh のラッパーとして後から追加する）
- Intel / Universal バイナリ
- 自動アップデート機能

## 全体の流れ

```
[開発者] git tag v0.2.0 && git push --tags
    └─▶ GitHub Actions (macos-15, arm64)
          shellcheck → swift test → build → ad-hoc 署名 → zip + sha256 → Releases

[ユーザー] curl -fsSL https://raw.githubusercontent.com/hiromaily/mac-input-switcher/main/install.sh | bash
    └─▶ 最新リリースの zip と sha256 を取得・検証
        → ローカル証明書で再署名 → ~/Applications に配置 → LaunchAgent 登録
```

## コンポーネント

### install.sh（リポジトリ直下）

`curl | bash` で実行されるので、このファイル単体で完結させる。LaunchAgent の plist はヒアドキュメントで埋め込む。
stdin はパイプなので、対話入力は一切読まない。

使い方:

```sh
install.sh                    # 最新リリースをインストール / アップデート
VERSION=v0.2.0 install.sh     # 指定バージョンをインストール
install.sh --app <path>       # ローカルの .app をインストール（make install 用）
install.sh --uninstall        # アンインストール
```

インストール処理:

1. 事前チェック: `sw_vers -productVersion` のメジャーが 15 以上で、`uname -m` が `arm64` であること。満たさなければ理由を表示して終了する（exit 1）
2. 取得（`--app` 指定時はスキップ）: 一時ディレクトリに次の 2 つをダウンロードする
   - `https://github.com/hiromaily/mac-input-switcher/releases/latest/download/MacInputSwitcher.zip`
   - 同じ場所の `MacInputSwitcher.zip.sha256`
   - `VERSION` 指定時は `releases/download/$VERSION/...` を使う
   - `shasum -a 256 -c` で検証し、一致しなければ終了する。`ditto -x -k` で展開する
3. 署名用 ID: キーチェーンに `mac-input-switcher-local` がなければ作成する（現行 `scripts/create-signing-cert.sh` と同じ処理）。初回は証明書の信頼設定で macOS のパスワードダイアログが出る
4. 再署名: `codesign --force --options runtime --sign mac-input-switcher-local <app>` のあと、`codesign --verify --strict` で検証する
5. 配置:
   - `launchctl bootout gui/$UID/com.hiromaily.mac-input-switcher` を実行する（失敗は無視）
   - `~/Applications/MacInputSwitcher.app` を置き換える
   - `~/Library/LaunchAgents/com.hiromaily.mac-input-switcher.plist` を書き出し、`launchctl bootstrap` する
6. 案内を表示する: 入力監視とアクセシビリティを許可すること、ログの場所、アンインストール方法

アンインストール処理（`--uninstall`）:

1. `launchctl bootout`（失敗は無視）
2. plist と `~/Applications/MacInputSwitcher.app` を削除する
3. `tccutil reset ListenEvent com.hiromaily.mac-input-switcher`、`tccutil reset Accessibility com.hiromaily.mac-input-switcher`、`tccutil reset PostEvent com.hiromaily.mac-input-switcher` を実行する（失敗は無視）
4. 署名用証明書は削除しない。削除コマンド（`security delete-identity -c mac-input-switcher-local`）を表示する

エラー処理: `set -euo pipefail`。各ステップの失敗時は、何が失敗したかを stderr に出して非 0 で終了する。一時ディレクトリは `trap` で削除する。

### Makefile

インストール処理が重複しないよう、`install.sh` に一本化する。

- `VERSION ?= 0.0.0-dev` を追加する。`build` で Info.plist の `__VERSION__` を置換する
- `install`: `build` の後に `./install.sh --app $(APP)` を実行する
- `uninstall`: `./install.sh --uninstall` を実行する
- `sign` ターゲットは削除する（署名は install.sh が担う）

### 削除するファイル

- `scripts/create-signing-cert.sh`（install.sh に統合）
- `LaunchAgent/com.hiromaily.mac-input-switcher.plist`（install.sh に埋め込み）

### Resources/Info.plist

- `CFBundleShortVersionString` を `__VERSION__` にする
- `CFBundleVersion` は `1` のまま

### .github/workflows/release.yml

- トリガー: `push: tags: ['v*']`
- ランナー: `macos-15`（arm64）
- 権限: `contents: write`
- ステップ:
  1. checkout
  2. `shellcheck install.sh`
  3. `swift test`
  4. `make build VERSION=${GITHUB_REF_NAME#v}`
  5. `codesign --force --sign - build/MacInputSwitcher.app`
  6. `ditto -c -k --keepParent build/MacInputSwitcher.app MacInputSwitcher.zip`
  7. `shasum -a 256 MacInputSwitcher.zip > MacInputSwitcher.zip.sha256`
  8. `gh release create "$GITHUB_REF_NAME" MacInputSwitcher.zip MacInputSwitcher.zip.sha256 --generate-notes`

### README

- 冒頭: 一般ユーザー向けの「インストール」「アップデート（同じコマンドを再実行）」「アンインストール」
- 証明書作成時にパスワードダイアログが出る理由を短く説明する
- 開発者向け（`make install` / `make test` / リリース手順）は後半にまとめる
- トラブルシュートの記述を新しい構成に合わせて更新する

## テスト

自動（CI）:

- `shellcheck install.sh`
- `swift test`

手動:

1. `make install` で、`--app` 経由のインストールと起動ができる
2. 実際のリリースから `curl | bash` で新規インストールし、権限を許可すると動作する
3. 同じコマンドで再インストールしても、権限ダイアログが出ずに動作する
4. `--uninstall` で .app・plist が消え、システム設定の権限一覧からもエントリが消える
5. sha256 が一致しない場合（zip を改変）にインストールが中断される
