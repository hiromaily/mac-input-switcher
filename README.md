# mac-input-switcher

US キーボードで **左⌘単独押し → 英語入力 / 右⌘単独押し → 日本語入力** に切り替える macOS 常駐ツール。
Karabiner-Elements のような仮想ドライバーを使わず、macOS 標準 API（CGEventTap）のみで動作します。

## 動作条件

- macOS 15 以降 / Apple Silicon
- Command Line Tools（`xcode-select --install`）
- 入力ソースに「ABC」と「日本語 - ローマ字入力」を追加済み

## セットアップ

```sh
scripts/create-signing-cert.sh   # 初回のみ。ログインパスワードを求められます
make install
```

初回起動時に許可ダイアログが出るので、システム設定 > プライバシーとセキュリティ で **入力監視** と **アクセシビリティ** に `MacInputSwitcher` を許可します。
許可されると再起動なしで動き出します（`make logs` で `mac-input-switcher started` を確認）。

## 使い方

| 操作 | 結果 |
|---|---|
| 左⌘を単独で押して離す（0.5 秒以内） | 英語入力 |
| 右⌘を単独で押して離す（0.5 秒以内） | 日本語入力 |
| ⌘+キー、⌘+クリック、長押し | 切り替えない（通常の⌘として動作） |

パスワード入力欄など Secure Input 中は macOS の制約で動作しません。

## 運用

```sh
make logs        # ログを表示
make install     # 再ビルドして再インストール（権限は維持されます）
make uninstall   # アンインストール
make test        # ユニットテスト
```

## 手動テスト

1. テキストエディタで左⌘単独押し → 英語、右⌘単独押し → 日本語に切り替わる
2. ⌘C / ⌘V / ⌘Tab / ⌘+クリックで入力モードが変わらない
3. `make install` で再インストール後も権限ダイアログが出ず動作する
4. `launchctl kill TERM gui/$(id -u)/com.hiromaily.mac-input-switcher` 後、数秒で自動復帰する（`make logs` で `started` を確認）

## トラブルシュート

- 動かない: `make logs` で `waiting for permissions` が出ていないか確認し、権限を付け直す（許可されれば再起動なしで動き出します）
- 権限一覧に古いエントリが残る: 一度削除してから `make install` し直す
- 「<ターミナルアプリ> would like to receive keystrokes」と出る: `.build/release/mac-input-switcher` をターミナルから直接実行すると、権限の要求元がターミナルアプリになります。常駐は LaunchAgent（`make install`）経由で行ってください
- 許可ダイアログが閉じられない: `killall universalAccessAuthWarn` で閉じられます（必要時に macOS が再起動します）
