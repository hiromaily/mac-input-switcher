---
paths:
  - "Sources/**"
  - "Tests/**"
  - "Package.swift"
---

# Swift コードの注意

## 置き場所とテスト

- 判定ロジック（何をするかを決める処理）は `Sources/InputSwitcherCore/` に、副作用のない形で置く。swift-testing（`@Suite` / `@Test` / `#expect`）でテストを先に書き、失敗を確認してから実装する
- 副作用のある macOS 呼び出し（イベントの送信、イベントタップ、権限 API、`Process` / `execv` など）は、`main.swift` に置くか、プロトコルの裏に置く。既存の例: キーの合成は `InputSourceSwitching` の実装 `JISKeyInputSourceSwitcher`（Core 内、CoreGraphics を使用）で、キーコードの選択や目印の判定はテストしている
- Core が CoreGraphics の型（`CGEventType` / `CGEventFlags`）を使うのは許容している（`EventTranslator`）。既存コードを「Core から CoreGraphics を追い出す」目的で動かさない
- Swift 6 言語モード、`platforms: [.macOS(.v15)]`、サードパーティへの依存なし。Command Line Tools だけでビルドできる状態を保つ（Xcode に依存しない）

## イベント

- イベントタップは listen-only。キーイベントを書き換えたり破棄したりしない
- 自分で合成した英数 / かなキーは、`eventSourceUserData` の目印（`JISKeyInputSourceSwitcher.isSynthesized`）で見分けて無視する

## 権限（入力監視・アクセシビリティ）

- `CGPreflightListenEventAccess` / `AXIsProcessTrusted` の結果は、権限なしで起動したプロセスの中では、許可した後も更新されない
- そのため待機中は、自分自身を `--check-permissions` 付きの子プロセスとして起動して確認する。すべて許可されたら `execv` で再起動する（`PermissionProbe` / `PermissionWatch`）
- 許可ダイアログは起動時に 1 回だけ出す（`missingPermissions(prompt: true)`）

## ログ

- 定義している場所
  - `mac-input-switcher started`: `Sources/mac-input-switcher/main.swift`
  - `waiting for permissions: …` / `all permissions granted; restarting`: `Sources/InputSwitcherCore/PermissionWatch.swift`。文言は `Tests/InputSwitcherCoreTests/PermissionWatchTests.swift` が検証している
- 参照している場所
  - README のトラブルシュート: `waiting for permissions`
  - `verify-on-device` / `release` スキルのログ確認: 3 つとも
- 文言を変えるときは、定義・テスト・参照している場所をまとめて直す

## 動作確認

- `.build/release/mac-input-switcher` をターミナルから直接実行すると、権限を要求する主体がターミナルアプリになる。動作確認は `make install` と `verify-on-device` スキルの手順で行う
