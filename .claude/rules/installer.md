---
paths:
  - "install.sh"
  - "scripts/**"
  - "Makefile"
  - ".github/workflows/**"
---

# インストーラー・ビルド・リリースの注意

## install.sh は `curl | bash` で実行される

- 1 ファイルで完結させる（他のファイルを読み込まない。LaunchAgent の plist もヒアドキュメントで中に持つ）
- stdin を読まない（パイプになっているため）
- 処理はすべて関数の中に置き、最終行は `{ main "$@"; }` のままにする。こうしておくと、途中で途切れたダウンロードは構文エラーになり、何も実行されない

## bash 3.2（macOS 標準）と 5.2（Homebrew）の両方で動かす

- 連想配列、`mapfile`、`${var,,}` / `${var^^}` を使わない
- `set -u` のもとで空の配列を `"${arr[@]}"` で展開しない
- `${var//pat/…&…}` を使わない。bash 5.2 では置換後の文字列の `&` が、一致した部分に展開される。文字の置き換えには `sed` を使う

## テスト

- `install.sh` を、実際の HOME やシステムコマンドに向けて実行しない。過去に、テストの不備で利用者のアプリと LaunchAgent を消したことがある
- `scripts/test-install.sh` のスタブ（`launchctl` / `tccutil` / `security` / `codesign` / `id`）を `PATH` の先頭に置き、`HOME` は一時ディレクトリにする。新しいテストも `run_stubbed` か、`HOME="$TMP/..."` を明示する形で書く
- 失敗する経路や分岐を足すときは、テストを先に書いて失敗を確認してから実装する
- 確認は次の 3 つで行う
  - `scripts/test-install.sh`
  - `env PATH="/bin:/usr/bin:$PATH" scripts/test-install.sh`（`/bin/bash` 3.2 で実行される）
  - `shellcheck install.sh scripts/test-install.sh`
- エラーメッセージはテストが部分一致で検証している。文言を変えるときは、テストも一緒に直す

## 変えると既存ユーザーの更新や権限が壊れるもの

変える必要があるときは、移行方法を設計してから変える。

- 署名用 ID 名 `mac-input-switcher-local`（権限は、この証明書から決まる ID に紐づく）
- リリースのファイル名 `MacInputSwitcher.zip` / `MacInputSwitcher.zip.sha256`（`install.sh` は `releases/latest/download/` から取得する）
- インストール先 `~/Applications/MacInputSwitcher.app`、LaunchAgent の Label `com.hiromaily.mac-input-switcher`
- 環境変数 `MAC_INPUT_SWITCHER_VERSION`（README で案内している）

## Makefile とワークフロー

- `make build VERSION=…` は、バージョンをコマンドラインで渡す（Makefile は環境変数の `VERSION` を無視する）
- `make install` / `make uninstall` は `install.sh --app` / `--uninstall` を呼ぶだけにして、処理を重複させない
- ワークフローは `v*` タグで起動する。`-` を含むタグ（例 `v1.0.0-rc1`）はプレリリースとして公開され、`releases/latest` の対象外になる
- ワークフロー内のシェルは bash 3.2 の可能性がある。空の配列の展開を避ける
