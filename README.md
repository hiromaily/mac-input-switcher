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
curl -fsSL https://raw.githubusercontent.com/hiromaily/mac-input-switcher/main/install.sh | MAC_INPUT_SWITCHER_VERSION=v0.2.0 bash
```

## アップデート

インストールと同じコマンドをもう一度実行します。許可はそのまま引き継がれます。

## アンインストール

```sh
curl -fsSL https://raw.githubusercontent.com/hiromaily/mac-input-switcher/main/install.sh | bash -s -- --uninstall
```

アプリ、自動起動の設定、ログファイル、入力監視・アクセシビリティの許可を削除します。署名用証明書はキーチェーンに残ります。不要なら `security delete-identity -c mac-input-switcher-local` で削除できます。

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
- 「failed to start the LaunchAgent」で止まった: システム設定 > 一般 > ログイン項目 の「バックグラウンドでの実行を許可」で `MacInputSwitcher` がオフになっていないか確認し、オンにしてからインストールのコマンドを再実行してください
- 「codesign がキーチェーン内のキーにアクセスしようとしています」と出た: インストーラーが作った署名用の鍵を使うためです。ログインパスワードを入力し「常に許可」を選んでください
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

GitHub Actions がテスト・ビルドを行い、`MacInputSwitcher.zip` とその sha256 を Releases に公開します。`v1.0.0-rc1` のように `-` を含むタグはプレリリースとして公開され、`install.sh` の既定（最新リリース）の対象になりません。`install.sh` は、既定で最新リリースを取得します。

### 手動テスト

1. テキストエディタで左⌘単独押し → 英語、右⌘単独押し → 日本語に切り替わる
2. ⌘C / ⌘V / ⌘Tab / ⌘+クリックで入力モードが変わらない
3. インストールコマンドを再実行しても、権限ダイアログが出ずに動作する
4. `launchctl kill TERM gui/$(id -u)/com.hiromaily.mac-input-switcher` の後、数秒で自動復帰する（ログで `started` を確認）
5. アンインストール後、システム設定の権限一覧から `MacInputSwitcher` が消えている
