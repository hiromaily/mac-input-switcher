# ⌘キー単独押しによる入力ソース切り替え 設計

- 日付: 2026-10-09
- ステータス: 承認待ち

## 背景と目的

US キーボードで、左⌘単独押しで英語入力、右⌘単独押しで日本語入力に切り替えたい。
従来は Karabiner-Elements を使っていたが、仮想ドライバー（DriverKit）の設定ができない不具合で利用できなくなった。
カーネル拡張・システム拡張・サードパーティ製アプリに依存しない仕組みで同等の機能を実現する。

## 要件

- 左⌘を単独で押して離す → 英語入力（ABC）に切り替える
- 右⌘を単独で押して離す → 日本語入力（ことえり）に切り替える
- ⌘C 等のショートカット、⌘+クリック、⌘の長押しでは切り替えない
- ⌘キー本来の動作は一切変更しない（イベントの書き換え・破棄をしない）
- ドライバー・システム拡張・サードパーティ製ランタイムに依存しない
- ログイン時に自動起動し、異常終了時も自動復帰する

## 非要件（YAGNI）

- メニューバーアイコン・GUI 設定画面
- キー割り当てのカスタマイズ（閾値以外）
- 日本語 IME 以外の入力ソース対応
- Secure Input 有効時（パスワード入力欄など）の動作。macOS がイベントタップを止めるため動作しないことを仕様として許容する

## 前提環境

- macOS 15 以降 / Apple Silicon
- Command Line Tools のみ（Xcode 不要）、Swift 6.1
- 入力ソース: ABC と ことえり（ローマ字入力）

## アーキテクチャ

画面を持たない常駐プロセス（`LSUIElement` の `.app`）を LaunchAgent で起動する。

```
キーボード/マウス
      │ (CGEventTap, listen-only)
      ▼
main.swift ──イベント変換──▶ CommandTapDetector ──Action──▶ InputSourceSwitcher
                                (純粋な状態機械)                (英数/かなキー合成)
```

### ディレクトリ構成

```
mac-input-switcher/
├── Package.swift
├── Sources/
│   ├── InputSwitcherCore/
│   │   ├── CommandTapDetector.swift
│   │   └── InputSourceSwitcher.swift
│   └── mac-input-switcher/
│       └── main.swift
├── Tests/InputSwitcherCoreTests/
│   └── CommandTapDetectorTests.swift
├── Resources/Info.plist
├── LaunchAgent/com.hiromaily.mac-input-switcher.plist
├── scripts/create-signing-cert.sh
└── Makefile
```

## コンポーネント

### CommandTapDetector（InputSwitcherCore）

macOS API に依存しない状態機械。入力は抽象化したイベント、出力は切り替え指示。

入力イベント:

```swift
enum InputEvent {
    case commandDown(side: Side, timestamp: TimeInterval)
    case commandUp(side: Side, timestamp: TimeInterval)
    case otherModifierChanged   // Shift/Option/Control/Fn、反対側⌘以外の修飾キー変化
    case keyDown                // 任意の通常キー押下
    case mouseDown              // 任意のマウスボタン押下
}
enum Side { case left, right }
enum Action { case switchToEnglish, switchToJapanese }
```

公開 API: `mutating func handle(_ event: InputEvent) -> Action?`

状態遷移:

| 状態 | イベント | 次状態 | 出力 |
|---|---|---|---|
| idle | commandDown(side, t) | pending(side, t) | なし |
| idle | その他 | idle | なし |
| pending(s, t0) | commandUp(s, t1) かつ t1−t0 ≤ 閾値 | idle | 左→switchToEnglish / 右→switchToJapanese |
| pending(s, t0) | commandUp(s, t1) かつ t1−t0 > 閾値 | idle | なし |
| pending(s, _) | commandDown(反対側) | cancelled | なし |
| pending | keyDown / mouseDown / otherModifierChanged | cancelled | なし |
| cancelled | commandUp（両⌘とも離れた時点） | idle | なし |
| cancelled | その他 | cancelled | なし |

- 閾値は初期値 500ms。イニシャライザ引数で変更可能とする。
- cancelled 中は押下中の⌘の集合を追跡し、すべて離れたら idle に戻る。

### InputSourceSwitcher（InputSwitcherCore）

- `switchToEnglish()`: JIS 英数キー（`kVK_JIS_Eisu` = 102）の keyDown/keyUp を `CGEvent.post(tap: .cghidEventTap)` で送る
- `switchToJapanese()`: JIS かなキー（`kVK_JIS_Kana` = 104）を同様に送る
- 合成イベントの修飾フラグは空にする（⌘付きにならないように）
- プロトコル `InputSourceSwitching` を定義し、将来 `TISSelectInputSource` 方式へ差し替え可能にする

`TISSelectInputSource` を採用しない理由: 日本語 IME への切り替えでメニューバー表示と実際の入力モードが食い違う既知の問題があるため。

### main.swift（実行ファイル）

1. 権限チェック
   - 入力監視: `CGPreflightListenEventAccess()`、不足時 `CGRequestListenEventAccess()`
   - アクセシビリティ: `AXIsProcessTrustedWithOptions`（プロンプト付き）
   - いずれか不足ならログを出して終了コード 1 で終了（LaunchAgent が再起動する）
2. `CGEvent.tapCreate` で listen-only タップを作成
   - 対象: `flagsChanged`, `keyDown`, `leftMouseDown`, `rightMouseDown`, `otherMouseDown`
3. イベント変換
   - `flagsChanged` かつ keycode 55（左⌘）/ 54（右⌘）: flags の `maskCommand` 有無と左右デバイスフラグ（`NX_DEVICELCMDKEYMASK` 0x08 / `NX_DEVICERCMDKEYMASK` 0x10）で down/up を判定
   - その他の `flagsChanged` → `otherModifierChanged`
   - `keyDown` → `keyDown`（ただし自身が合成した keycode 102/104 は無視）
   - マウス押下 → `mouseDown`
4. `tapDisabledByTimeout` / `tapDisabledByUserInput` 受信時は `CGEvent.tapEnable(tap:enable:true)` で再有効化しログに記録
5. `CFRunLoopRun()` で常駐

## 署名と導入

### 署名

ad-hoc 署名ではビルドごとに cdhash が変わり、TCC（権限）許可が失効する。
`scripts/create-signing-cert.sh` でログインキーチェーンに自己署名のコード署名証明書 `mac-input-switcher-local` を一度だけ作成し、常にこれで署名する。
designated requirement が「Bundle ID + 証明書」となるため、再ビルド後も許可が維持される。

### Makefile ターゲット

| ターゲット | 内容 |
|---|---|
| `make test` | `swift test` |
| `make build` | `swift build -c release` → `build/MacInputSwitcher.app` を組み立て |
| `make sign` | `codesign --force --options runtime --sign mac-input-switcher-local` |
| `make install` | build + sign → `~/Applications` に配置 → LaunchAgent を `~/Library/LaunchAgents` に配置し `launchctl bootstrap gui/$UID` |
| `make uninstall` | `launchctl bootout` → plist と `.app` を削除 |
| `make logs` | ログを tail |

### LaunchAgent

- Label: `com.hiromaily.mac-input-switcher`
- `RunAtLoad = true`, `KeepAlive = true`
- `ThrottleInterval = 10`（権限不足時の再起動ループを抑制）
- 標準出力/エラー: `~/Library/Logs/mac-input-switcher.log`

### Info.plist

- `CFBundleIdentifier = com.hiromaily.mac-input-switcher`
- `LSUIElement = true`

### 初回セットアップ手順

1. `scripts/create-signing-cert.sh`
2. `make install`
3. システム設定 > プライバシーとセキュリティ で「入力監視」「アクセシビリティ」に MacInputSwitcher を許可
4. `launchctl kickstart -k gui/$UID/com.hiromaily.mac-input-switcher`

## エラーハンドリング

| 状況 | 挙動 |
|---|---|
| 権限不足 | プロンプト表示・ログ出力・exit 1、LaunchAgent が 10 秒間隔で再起動 |
| タップ作成失敗 | ログ出力・exit 1 |
| タップがシステムに無効化された | 即時再有効化・ログ出力 |
| Secure Input 中 | イベントが届かず何もしない（許容） |

## テスト

### 自動テスト（swift-testing）

`CommandTapDetector` を対象に以下を検証する:

- 左⌘単独押し（閾値内）→ switchToEnglish
- 右⌘単独押し（閾値内）→ switchToJapanese
- ⌘押下中に keyDown（⌘C）→ なし
- ⌘押下中に mouseDown → なし
- ⌘押下中に Shift 等 → なし
- 閾値超えの長押し → なし
- 左⌘押下中に右⌘押下 → 両方離してもなし、その後の単独押しは正常に判定
- キャンセル後に idle へ復帰し、次の単独押しが判定される
- カスタム閾値が反映される

### 手動テスト（README に記載）

- テキストエディタで左⌘/右⌘単独押しで入力モードが切り替わる
- ⌘C/⌘V/⌘Tab、⌘+クリックで切り替わらない
- 再ビルド・再インストール後も権限が維持される
- プロセスを kill しても自動復帰する
