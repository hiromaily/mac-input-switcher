# mac-input-switcher

US キーボードで **左⌘単独押し → 英語入力 / 右⌘単独押し → 日本語入力** に切り替える macOS 常駐ツール。
Karabiner-Elements のような仮想ドライバーを使わず、macOS 標準 API（CGEventTap）のみで動作します。

## 動作条件

- macOS 15 以降 / Apple Silicon
- Command Line Tools（`xcode-select --install`）
- 入力ソースに「ABC」と「日本語（ことえり）」を追加済み

## セットアップ

```sh
scripts/create-signing-cert.sh   # 初回のみ。ログインパスワードを求められます
make install
```

システム設定 > プライバシーとセキュリティ で **入力監視** と **アクセシビリティ** に `MacInputSwitcher` を許可し、再起動します:

```sh
launchctl kickstart -k gui/$(id -u)/com.hiromaily.mac-input-switcher
```

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
4. `pkill -f mac-input-switcher` 後、数秒で自動復帰する（`make logs` で `started` を確認）

## トラブルシュート

- 動かない: `make logs` で `permission is missing` が出ていないか確認し、権限を付け直す
- 権限一覧に古いエントリが残る: 一度削除してから `make install` し直す
