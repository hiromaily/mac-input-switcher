---
paths:
  - "Sources/**"
  - "Tests/**"
  - "Package.swift"
---

# Swift コードの注意

## 置き場所とテスト

- macOS の API（CoreGraphics / ApplicationServices / `Process` / `execv` など）を呼ぶのは `Sources/mac-input-switcher/main.swift` だけにする
- 判定ロジックは `Sources/InputSwitcherCore/` に、macOS に依存しない形で置く。swift-testing（`@Suite` / `@Test` / `#expect`）でテストを先に書き、失敗を確認してから実装する
- Swift 6 言語モード、`platforms: [.macOS(.v15)]`、サードパーティへの依存なし。Command Line Tools だけでビルドできる状態を保つ（Xcode に依存しない）

## イベント

- イベントタップは listen-only。キーイベントを書き換えたり破棄したりしない
- 自分で合成した英数 / かなキーは、`eventSourceUserData` の目印（`JISKeyInputSourceSwitcher.isSynthesized`）で見分けて無視する

## 権限（入力監視・アクセシビリティ）

- `CGPreflightListenEventAccess` / `AXIsProcessTrusted` の結果は、権限なしで起動したプロセスの中では、許可した後も更新されない
- そのため待機中は、自分自身を `--check-permissions` 付きの子プロセスとして起動して確認する。すべて許可されたら `execv` で再起動する（`PermissionProbe` / `PermissionWatch`）
- 許可ダイアログは起動時に 1 回だけ出す（`missingPermissions(prompt: true)`）

## ログ

- `mac-input-switcher started`、`waiting for permissions: …`、`all permissions granted; restarting` は、README のトラブルシュートと `verify-on-device` スキルが参照している。文言を変えるときは、これらも直す

## 動作確認

- `.build/release/mac-input-switcher` をターミナルから直接実行すると、権限を要求する主体がターミナルアプリになる。動作確認は `make install` と `verify-on-device` スキルの手順で行う
