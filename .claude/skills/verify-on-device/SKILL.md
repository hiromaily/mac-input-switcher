---
name: verify-on-device
description: mac-input-switcher を実機にインストールし、入力監視・アクセシビリティの許可と⌘キーでの入力切り替えを確認する手順。install.sh・権限まわり・main.swift を変更した後や、リリースを入れ直して確認するときに使う。
---

# 実機での確認

## 原則

- この手順は、ユーザーの実環境（`~/Applications`、LaunchAgent、TCC、ログインキーチェーン）を変えます。どの操作を実行するかを先に示し、了承を得てから進めてください
- `make uninstall` と `install.sh --uninstall` は、TCC の権限エントリも消します。そのあとユーザーは権限を付け直す必要があります
- 権限の付与と、⌘キーの動作確認はユーザーにしかできません。依頼したら、ログを見ながら待ちます

## 1. 入れ方を選ぶ

| 確かめたいもの | コマンド |
|---|---|
| 手元のブランチのビルド | `make install` |
| 公開済みのリリース | `curl -fsSL https://raw.githubusercontent.com/hiromaily/mac-input-switcher/main/install.sh \| bash` |
| 権限なしの状態からの初回体験 | 先に `make uninstall`（または `--uninstall`）を実行してから、上のどちらか |

## 2. ログを確認する

```bash
sleep 4; tail -n 3 ~/Library/Logs/mac-input-switcher.log
launchctl print gui/$(id -u)/com.hiromaily.mac-input-switcher | grep -E '^\s*(state|pid) ='
```

| ログ | 意味 |
|---|---|
| `mac-input-switcher started` | 権限がそろい、動作中 |
| `waiting for permissions: Input Monitoring, Accessibility` | 権限の許可を待っている（足りないものが表示される） |
| `all permissions granted; restarting` | 待機中に許可が検出され、自分自身を再起動した |

## 3. 権限の許可を依頼する（`waiting` のとき）

システム設定 > プライバシーとセキュリティ で、**入力監視** と **アクセシビリティ** の両方で `MacInputSwitcher` を ON にしてもらいます。そのあと、ログをポーリングします。ユーザーの操作待ちで最大 5 分かかるので、Bash ツールの `timeout` を 320000 以上にします（既定の 2 分では途中で打ち切られます）。

```bash
for i in $(seq 1 150); do tail -n 1 ~/Library/Logs/mac-input-switcher.log | grep -q started && break; sleep 2; done
tail -n 4 ~/Library/Logs/mac-input-switcher.log
```

許可すれば、再起動しなくても `all permissions granted; restarting` → `started` と進むのが正しい動きです。

## 4. 動作を確認してもらう

左⌘の単独押しで英語、右⌘の単独押しで日本語に切り替わることを、ユーザーに確認してもらいます。⌘C などのショートカットで入力モードが変わらないことも確かめます。

## 5. 権限が維持されることを確認する（必要なとき）

同じ方法でもう一度インストールし、権限ダイアログが出ずにすぐ `started` になることを確認します。

## ハマりどころ

- **TCC の状態は直接読めない。** `TCC.db` は Full Disk Access がないと開けず、unified log でも詳細は伏せられています。判断はアプリのログで行います
- **アクセシビリティが ON にならない。** ユーザーが ON にしたはずなのに OFF のまま、ということが過去にありました。ログが進まないときは、システム設定でどう表示されているかをユーザーに確認してもらいます
- **許可ダイアログを出し直したい。** ダイアログは起動時に 1 回だけ出ます。`launchctl kickstart -k gui/$(id -u)/com.hiromaily.mac-input-switcher` で再起動すると、もう一度出ます
- **新しいプロセスでの判定を確かめたい。** 同じく `kickstart -k` を使います。再起動後も `waiting` のままなら、権限が実際には付いていません
- **ターミナルから直接実行しない。** `.build/release/mac-input-switcher` を直接実行すると、権限を要求する主体がターミナルアプリになります
