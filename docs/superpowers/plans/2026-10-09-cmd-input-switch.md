# ⌘キー単独押し入力切り替え Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 左⌘単独押しで英語入力、右⌘単独押しで日本語入力に切り替える常駐ツールを、ドライバー不要の macOS 標準 API だけで作る。

**Architecture:** listen-only の `CGEventTap` で受けた生イベントを `EventTranslator` が抽象イベントに変換し、純粋な状態機械 `CommandTapDetector` が単独押しを判定、`JISKeyInputSourceSwitcher` が JIS 英数/かなキーを合成して IME を切り替える。`.app` に包んで自己署名証明書で署名し、LaunchAgent で常駐させる。

**Tech Stack:** Swift 6.1（Command Line Tools のみ）、Swift Package Manager、swift-testing、CoreGraphics / ApplicationServices、make、launchd

**Spec:** `docs/superpowers/specs/2026-10-09-cmd-input-switch-design.md`

> **Note:** 実装時点の作業記録。以後の変更（権限待ちの常駐化、合成イベントの目印による除外など）は反映していないため、現在の仕様は Spec とソースを参照すること。

## Global Constraints

- macOS 15 以降 / Apple Silicon。`Package.swift` は `platforms: [.macOS(.v15)]`、`swift-tools-version:6.0`（Swift 6 言語モード）
- Xcode 不要。`swift build` / `swift test` / `codesign` / `launchctl` のみ使用
- サードパーティ依存なし
- イベントは listen-only で受け、書き換え・破棄しない
- 単独押し閾値の初期値 500ms（`0.5` 秒、境界値は「切り替える」側に含む）
- Bundle ID / LaunchAgent Label: `com.hiromaily.mac-input-switcher`
- アプリ名: `MacInputSwitcher.app`、実行ファイル名: `mac-input-switcher`
- 署名 ID: `mac-input-switcher-local`
- ログ: `~/Library/Logs/mac-input-switcher.log`
- LaunchAgent: `RunAtLoad=true`, `KeepAlive=true`, `ThrottleInterval=10`
- 作業ブランチ: `feature/cmd-input-switch`（PR で main にマージ）

## Spec からの意図的な差分

- 生イベント → 抽象イベントの変換を `main.swift` から `InputSwitcherCore/EventTranslator.swift` に切り出す（テスト可能にするため）
- `InputSourceSwitching` は `switchToEnglish()/switchToJapanese()` ではなく `perform(_ action: Action)` の 1 メソッドにする（Detector の出力をそのまま渡せるため）

## Review Focus

1. **⌘の key-up 取りこぼし**（Secure Input 中に離した等）→ 次に同じ⌘を押した時点で回復し、以後の単独押しが効くこと（Task 1 `recoversWhenKeyUpWasLost`）
2. **起動時すでに⌘が押されていた／対応する down のない up** → 何もせず、以後正常に判定すること（Task 1 `strayKeyUpIsIgnored`）
3. **ちょうど閾値（500ms）で離す** → 切り替えること（Task 1 `releaseExactlyAtThresholdSwitches`）
4. **自分が合成した英数/かなキーが自分のタップに戻ってくる** → 無視されループや誤キャンセルを起こさないこと（Task 2 `synthesizedEisuKanaKeysAreIgnored`）
5. **片方の⌘を押したまま、もう片方を離す**（device フラグに反対側のビットが残る）→ 正しく up と判定すること（Task 2 `rightCommandReleasedWhileLeftHeldIsUp`）

## File Structure

| ファイル | 責務 |
|---|---|
| `Package.swift` | SwiftPM 定義（Core ライブラリ / 実行ファイル / テスト） |
| `Sources/InputSwitcherCore/CommandTapDetector.swift` | `Side`/`InputEvent`/`Action` 型と単独押し状態機械 |
| `Sources/InputSwitcherCore/EventTranslator.swift` | CGEvent の type/keycode/flags → `InputEvent` 変換 |
| `Sources/InputSwitcherCore/InputSourceSwitcher.swift` | `InputSourceSwitching` プロトコルと英数/かなキー合成実装 |
| `Sources/mac-input-switcher/main.swift` | 権限チェック、タップ登録、コールバック、ランループ |
| `Tests/InputSwitcherCoreTests/*.swift` | Core のユニットテスト |
| `Resources/Info.plist` | `.app` メタデータ（`LSUIElement`） |
| `LaunchAgent/com.hiromaily.mac-input-switcher.plist` | LaunchAgent テンプレート（`__APP_EXEC__`/`__LOG__` を置換） |
| `scripts/create-signing-cert.sh` | 自己署名コード署名証明書の作成 |
| `Makefile` | test/build/sign/install/uninstall/logs |
| `README.md` | セットアップ・手動テスト手順 |
| `.gitignore` | `.build/`, `build/` を追加 |

---

### Task 1: パッケージ雛形と CommandTapDetector

**Files:**
- Create: `Package.swift`
- Create: `Sources/InputSwitcherCore/CommandTapDetector.swift`
- Create: `Sources/mac-input-switcher/main.swift`（この Task では空の仮実装）
- Test: `Tests/InputSwitcherCoreTests/CommandTapDetectorTests.swift`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: なし
- Produces:
  - `public enum Side: Sendable, Equatable { case left, right }`
  - `public enum InputEvent: Sendable, Equatable { case commandDown(side: Side, timestamp: TimeInterval); case commandUp(side: Side, timestamp: TimeInterval); case otherModifierChanged; case keyDown; case mouseDown }`
  - `public enum Action: Sendable, Equatable { case switchToEnglish, switchToJapanese }`
  - `public struct CommandTapDetector { public init(threshold: TimeInterval = 0.5); public mutating func handle(_ event: InputEvent) -> Action? }`

- [ ] **Step 1: Package.swift と仮の main.swift を作成**

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "mac-input-switcher",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "InputSwitcherCore"),
        .executableTarget(name: "mac-input-switcher", dependencies: ["InputSwitcherCore"]),
        .testTarget(name: "InputSwitcherCoreTests", dependencies: ["InputSwitcherCore"]),
    ]
)
```

`Sources/mac-input-switcher/main.swift`（Task 3 で置き換える）:

```swift
// Replaced in Task 3.
```

`.gitignore` に以下が無ければ追記:

```
.build/
build/
```

- [ ] **Step 2: 失敗するテストを書く**

`Tests/InputSwitcherCoreTests/CommandTapDetectorTests.swift`:

```swift
import Testing
@testable import InputSwitcherCore

@Suite struct CommandTapDetectorTests {
    @Test func leftTapSwitchesToEnglish() {
        var detector = CommandTapDetector()
        #expect(detector.handle(.commandDown(side: .left, timestamp: 0)) == nil)
        #expect(detector.handle(.commandUp(side: .left, timestamp: 0.1)) == .switchToEnglish)
    }

    @Test func rightTapSwitchesToJapanese() {
        var detector = CommandTapDetector()
        #expect(detector.handle(.commandDown(side: .right, timestamp: 0)) == nil)
        #expect(detector.handle(.commandUp(side: .right, timestamp: 0.1)) == .switchToJapanese)
    }

    @Test(arguments: [InputEvent.keyDown, .mouseDown, .otherModifierChanged])
    func interveningEventCancels(event: InputEvent) {
        var detector = CommandTapDetector()
        _ = detector.handle(.commandDown(side: .left, timestamp: 0))
        #expect(detector.handle(event) == nil)
        #expect(detector.handle(.commandUp(side: .left, timestamp: 0.1)) == nil)
    }

    @Test func longPressDoesNotSwitch() {
        var detector = CommandTapDetector()
        _ = detector.handle(.commandDown(side: .left, timestamp: 0))
        #expect(detector.handle(.commandUp(side: .left, timestamp: 0.51)) == nil)
    }

    @Test func releaseExactlyAtThresholdSwitches() {
        var detector = CommandTapDetector()
        _ = detector.handle(.commandDown(side: .left, timestamp: 1.0))
        #expect(detector.handle(.commandUp(side: .left, timestamp: 1.5)) == .switchToEnglish)
    }

    @Test func bothCommandsPressedDoesNotSwitch() {
        var detector = CommandTapDetector()
        _ = detector.handle(.commandDown(side: .left, timestamp: 0))
        _ = detector.handle(.commandDown(side: .right, timestamp: 0.05))
        #expect(detector.handle(.commandUp(side: .right, timestamp: 0.1)) == nil)
        #expect(detector.handle(.commandUp(side: .left, timestamp: 0.15)) == nil)
        _ = detector.handle(.commandDown(side: .right, timestamp: 1))
        #expect(detector.handle(.commandUp(side: .right, timestamp: 1.1)) == .switchToJapanese)
    }

    @Test func recoversAfterCancellation() {
        var detector = CommandTapDetector()
        _ = detector.handle(.commandDown(side: .left, timestamp: 0))
        _ = detector.handle(.keyDown)
        _ = detector.handle(.commandUp(side: .left, timestamp: 0.1))
        _ = detector.handle(.commandDown(side: .left, timestamp: 1))
        #expect(detector.handle(.commandUp(side: .left, timestamp: 1.1)) == .switchToEnglish)
    }

    @Test func customThresholdIsHonored() {
        var detector = CommandTapDetector(threshold: 0.2)
        _ = detector.handle(.commandDown(side: .right, timestamp: 0))
        #expect(detector.handle(.commandUp(side: .right, timestamp: 0.3)) == nil)
    }

    @Test func recoversWhenKeyUpWasLost() {
        var detector = CommandTapDetector()
        _ = detector.handle(.commandDown(side: .left, timestamp: 0))
        // key-up never arrives
        _ = detector.handle(.commandDown(side: .left, timestamp: 5))
        #expect(detector.handle(.commandUp(side: .left, timestamp: 5.1)) == .switchToEnglish)
    }

    @Test func strayKeyUpIsIgnored() {
        var detector = CommandTapDetector()
        #expect(detector.handle(.commandUp(side: .right, timestamp: 0)) == nil)
        _ = detector.handle(.commandDown(side: .right, timestamp: 1))
        #expect(detector.handle(.commandUp(side: .right, timestamp: 1.1)) == .switchToJapanese)
    }
}
```

- [ ] **Step 3: テストが失敗することを確認**

Run: `swift test`
Expected: コンパイルエラー（`cannot find 'CommandTapDetector' in scope` 等）

- [ ] **Step 4: 実装**

`Sources/InputSwitcherCore/CommandTapDetector.swift`:

```swift
import Foundation

public enum Side: Sendable, Equatable {
    case left, right
}

public enum InputEvent: Sendable, Equatable {
    case commandDown(side: Side, timestamp: TimeInterval)
    case commandUp(side: Side, timestamp: TimeInterval)
    case otherModifierChanged
    case keyDown
    case mouseDown
}

public enum Action: Sendable, Equatable {
    case switchToEnglish, switchToJapanese
}

/// Detects a lone tap of the left or right Command key.
public struct CommandTapDetector: Sendable {
    public static let defaultThreshold: TimeInterval = 0.5

    private enum State: Equatable {
        case idle
        case pending(side: Side, start: TimeInterval)
        case cancelled
    }

    public let threshold: TimeInterval
    private var state: State = .idle
    private var pressed: Set<Side> = []

    public init(threshold: TimeInterval = CommandTapDetector.defaultThreshold) {
        self.threshold = threshold
    }

    public mutating func handle(_ event: InputEvent) -> Action? {
        switch event {
        case let .commandDown(side, timestamp):
            if pressed.contains(side) {
                // The previous key-up for this side was lost (e.g. swallowed by Secure Input).
                pressed.removeAll()
                state = .idle
            }
            pressed.insert(side)
            switch state {
            case .idle:
                state = .pending(side: side, start: timestamp)
            case .pending:
                state = .cancelled
            case .cancelled:
                break
            }
            return nil

        case let .commandUp(side, timestamp):
            pressed.remove(side)
            guard case let .pending(pendingSide, start) = state, pendingSide == side else {
                if pressed.isEmpty { state = .idle }
                return nil
            }
            state = .idle
            guard timestamp - start <= threshold else { return nil }
            return side == .left ? .switchToEnglish : .switchToJapanese

        case .otherModifierChanged, .keyDown, .mouseDown:
            if case .pending = state { state = .cancelled }
            return nil
        }
    }
}
```

- [ ] **Step 5: テストが通ることを確認**

Run: `swift test`
Expected: `CommandTapDetectorTests` の 10 テストがすべて pass（失敗 0）

- [ ] **Step 6: コミット**

```bash
git add Package.swift Sources Tests .gitignore
git commit -m "feat: add CommandTapDetector state machine"
```

---

### Task 2: EventTranslator と JIS キー切り替え

**Files:**
- Create: `Sources/InputSwitcherCore/EventTranslator.swift`
- Create: `Sources/InputSwitcherCore/InputSourceSwitcher.swift`
- Test: `Tests/InputSwitcherCoreTests/EventTranslatorTests.swift`
- Test: `Tests/InputSwitcherCoreTests/InputSourceSwitcherTests.swift`

**Interfaces:**
- Consumes: Task 1 の `InputEvent`, `Side`, `Action`
- Produces:
  - `public enum EventTranslator { public static func translate(type: CGEventType, keyCode: Int64, flags: CGEventFlags, timestamp: TimeInterval) -> InputEvent? }`
  - `public protocol InputSourceSwitching { func perform(_ action: Action) }`
  - `public struct JISKeyInputSourceSwitcher: InputSourceSwitching { public static let eisuKeyCode: CGKeyCode /*102*/; public static let kanaKeyCode: CGKeyCode /*104*/; public init(); public static func keyCode(for action: Action) -> CGKeyCode }`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/InputSwitcherCoreTests/EventTranslatorTests.swift`:

```swift
import CoreGraphics
import Testing
@testable import InputSwitcherCore

@Suite struct EventTranslatorTests {
    private let commandFlag = CGEventFlags.maskCommand.rawValue

    @Test func leftCommandDownAndUp() {
        let down = EventTranslator.translate(
            type: .flagsChanged, keyCode: 55,
            flags: CGEventFlags(rawValue: commandFlag | 0x08), timestamp: 1)
        #expect(down == .commandDown(side: .left, timestamp: 1))
        let up = EventTranslator.translate(
            type: .flagsChanged, keyCode: 55, flags: [], timestamp: 2)
        #expect(up == .commandUp(side: .left, timestamp: 2))
    }

    @Test func rightCommandDownAndUp() {
        let down = EventTranslator.translate(
            type: .flagsChanged, keyCode: 54,
            flags: CGEventFlags(rawValue: commandFlag | 0x10), timestamp: 1)
        #expect(down == .commandDown(side: .right, timestamp: 1))
        let up = EventTranslator.translate(
            type: .flagsChanged, keyCode: 54, flags: [], timestamp: 2)
        #expect(up == .commandUp(side: .right, timestamp: 2))
    }

    @Test func rightCommandReleasedWhileLeftHeldIsUp() {
        // Left still held: maskCommand and left device bit remain set.
        let up = EventTranslator.translate(
            type: .flagsChanged, keyCode: 54,
            flags: CGEventFlags(rawValue: commandFlag | 0x08), timestamp: 3)
        #expect(up == .commandUp(side: .right, timestamp: 3))
    }

    @Test(arguments: [Int64(56), 57, 58, 59, 63])  // shift, caps lock, option, control, fn
    func otherModifiersCancel(keyCode: Int64) {
        let event = EventTranslator.translate(
            type: .flagsChanged, keyCode: keyCode, flags: [], timestamp: 0)
        #expect(event == .otherModifierChanged)
    }

    @Test func regularKeyDown() {
        let event = EventTranslator.translate(type: .keyDown, keyCode: 8, flags: .maskCommand, timestamp: 0)
        #expect(event == .keyDown)
    }

    @Test(arguments: [Int64(102), 104])
    func synthesizedEisuKanaKeysAreIgnored(keyCode: Int64) {
        #expect(EventTranslator.translate(type: .keyDown, keyCode: keyCode, flags: [], timestamp: 0) == nil)
    }

    @Test(arguments: [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown])
    func mouseDown(type: CGEventType) {
        #expect(EventTranslator.translate(type: type, keyCode: 0, flags: [], timestamp: 0) == .mouseDown)
    }

    @Test func unrelatedEventsAreIgnored() {
        #expect(EventTranslator.translate(type: .keyUp, keyCode: 8, flags: [], timestamp: 0) == nil)
    }
}
```

`Tests/InputSwitcherCoreTests/InputSourceSwitcherTests.swift`:

```swift
import Testing
@testable import InputSwitcherCore

@Suite struct InputSourceSwitcherTests {
    @Test func englishUsesEisuKey() {
        #expect(JISKeyInputSourceSwitcher.keyCode(for: .switchToEnglish) == 102)
    }

    @Test func japaneseUsesKanaKey() {
        #expect(JISKeyInputSourceSwitcher.keyCode(for: .switchToJapanese) == 104)
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: コンパイルエラー（`cannot find 'EventTranslator' in scope`）

- [ ] **Step 3: 実装**

`Sources/InputSwitcherCore/InputSourceSwitcher.swift`:

```swift
import CoreGraphics

public protocol InputSourceSwitching {
    func perform(_ action: Action)
}

/// Switches input source by synthesizing the JIS Eisu / Kana keys,
/// which the Japanese IME honors even on a US keyboard.
public struct JISKeyInputSourceSwitcher: InputSourceSwitching {
    public static let eisuKeyCode: CGKeyCode = 102  // kVK_JIS_Eisu
    public static let kanaKeyCode: CGKeyCode = 104  // kVK_JIS_Kana

    public init() {}

    public static func keyCode(for action: Action) -> CGKeyCode {
        switch action {
        case .switchToEnglish: eisuKeyCode
        case .switchToJapanese: kanaKeyCode
        }
    }

    public func perform(_ action: Action) {
        let keyCode = Self.keyCode(for: action)
        let source = CGEventSource(stateID: .privateState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
                continue
            }
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
    }
}
```

`Sources/InputSwitcherCore/EventTranslator.swift`:

```swift
import CoreGraphics
import Foundation

/// Converts raw CGEvent fields into detector input events.
public enum EventTranslator {
    public static let leftCommandKeyCode: Int64 = 55
    public static let rightCommandKeyCode: Int64 = 54
    static let leftCommandDeviceMask: UInt64 = 0x08   // NX_DEVICELCMDKEYMASK
    static let rightCommandDeviceMask: UInt64 = 0x10  // NX_DEVICERCMDKEYMASK

    public static func translate(
        type: CGEventType,
        keyCode: Int64,
        flags: CGEventFlags,
        timestamp: TimeInterval
    ) -> InputEvent? {
        switch type {
        case .flagsChanged:
            switch keyCode {
            case leftCommandKeyCode:
                let isDown = flags.rawValue & leftCommandDeviceMask != 0
                return isDown ? .commandDown(side: .left, timestamp: timestamp)
                              : .commandUp(side: .left, timestamp: timestamp)
            case rightCommandKeyCode:
                let isDown = flags.rawValue & rightCommandDeviceMask != 0
                return isDown ? .commandDown(side: .right, timestamp: timestamp)
                              : .commandUp(side: .right, timestamp: timestamp)
            default:
                return .otherModifierChanged
            }
        case .keyDown:
            let synthesized = [
                Int64(JISKeyInputSourceSwitcher.eisuKeyCode),
                Int64(JISKeyInputSourceSwitcher.kanaKeyCode),
            ]
            return synthesized.contains(keyCode) ? nil : .keyDown
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return .mouseDown
        default:
            return nil
        }
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: 全テスト pass、失敗 0

- [ ] **Step 5: コミット**

```bash
git add Sources/InputSwitcherCore Tests
git commit -m "feat: add EventTranslator and JIS key input source switcher"
```

---

### Task 3: 実行ファイル（イベントタップ常駐）

**Files:**
- Modify: `Sources/mac-input-switcher/main.swift`（全置換）

**Interfaces:**
- Consumes: `CommandTapDetector.handle(_:)`, `EventTranslator.translate(type:keyCode:flags:timestamp:)`, `JISKeyInputSourceSwitcher().perform(_:)`
- Produces: 実行ファイル `.build/release/mac-input-switcher`。権限不足/タップ作成失敗で exit 1、正常時はログ `mac-input-switcher started` を stderr に出して常駐

- [ ] **Step 1: main.swift を実装**

注意: Swift 6 モードでは `kAXTrustedCheckOptionPrompt`（グローバル var）参照がエラーになるため、キー文字列 `"AXTrustedCheckOptionPrompt"` を直接使う。CGEventTapCallBack はキャプチャできないため、コンテキストは `userInfo` ポインタで渡す。

```swift
import ApplicationServices
import CoreGraphics
import Foundation
import InputSwitcherCore

func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(timestamp) \(message)\n".utf8))
}

final class TapContext {
    var detector = CommandTapDetector()
    let switcher: InputSourceSwitching = JISKeyInputSourceSwitcher()
    var tap: CFMachPort?
}

func hasRequiredPermissions() -> Bool {
    var granted = true
    if !CGPreflightListenEventAccess() {
        _ = CGRequestListenEventAccess()
        log("Input Monitoring permission is missing")
        granted = false
    }
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    if !AXIsProcessTrustedWithOptions(options) {
        log("Accessibility permission is missing")
        granted = false
    }
    return granted
}

let callback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        log("event tap disabled (type \(type.rawValue)); re-enabling")
        if let tap = context.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    let input = EventTranslator.translate(
        type: type,
        keyCode: event.getIntegerValueField(.keyboardEventKeycode),
        flags: event.flags,
        timestamp: TimeInterval(event.timestamp) / 1_000_000_000
    )
    if let input, let action = context.detector.handle(input) {
        context.switcher.perform(action)
    }
    return Unmanaged.passUnretained(event)
}

guard hasRequiredPermissions() else { exit(1) }

let context = TapContext()
let eventTypes: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
let mask = eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: mask,
    callback: callback,
    userInfo: Unmanaged.passUnretained(context).toOpaque()
) else {
    log("failed to create event tap")
    exit(1)
}
context.tap = tap

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
log("mac-input-switcher started")
CFRunLoopRun()
```

- [ ] **Step 2: リリースビルドが警告・エラーなく通ることを確認**

Run: `swift build -c release 2>&1 | grep -E "error|warning" ; echo "exit=$?"`
Expected: 何も出力されず `exit=1`（grep がマッチなし）

- [ ] **Step 3: 未署名バイナリで権限チェック経路を確認**

Run: `.build/release/mac-input-switcher; echo "exit=$?"`
Expected: ターミナルにまだ権限が無ければ `... permission is missing` が出て `exit=1`（許可ダイアログが出たら閉じてよい）。ターミナルに既に権限がある場合は `mac-input-switcher started` が出て常駐するので Ctrl+C で止める。この時点で左右⌘単独押しで切り替わるか試してよい。

- [ ] **Step 4: コミット**

```bash
git add Sources/mac-input-switcher/main.swift
git commit -m "feat: add event tap runner"
```

---

### Task 4: .app 化・署名・LaunchAgent・Makefile

**Files:**
- Create: `Resources/Info.plist`
- Create: `LaunchAgent/com.hiromaily.mac-input-switcher.plist`
- Create: `scripts/create-signing-cert.sh`
- Create: `Makefile`

**Interfaces:**
- Consumes: `.build/release/mac-input-switcher`
- Produces: `make test|build|sign|install|uninstall|logs`。`build/MacInputSwitcher.app`、`~/Applications/MacInputSwitcher.app`、`~/Library/LaunchAgents/com.hiromaily.mac-input-switcher.plist`

- [ ] **Step 1: Info.plist を作成**

`Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.hiromaily.mac-input-switcher</string>
    <key>CFBundleName</key>
    <string>MacInputSwitcher</string>
    <key>CFBundleExecutable</key>
    <string>mac-input-switcher</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 2: LaunchAgent テンプレートを作成**

`LaunchAgent/com.hiromaily.mac-input-switcher.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.hiromaily.mac-input-switcher</string>
    <key>ProgramArguments</key>
    <array>
        <string>__APP_EXEC__</string>
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
    <string>__LOG__</string>
    <key>StandardErrorPath</key>
    <string>__LOG__</string>
</dict>
</plist>
```

- [ ] **Step 3: plist の構文を確認**

Run: `plutil -lint Resources/Info.plist LaunchAgent/com.hiromaily.mac-input-switcher.plist`
Expected: 両方 `OK`

- [ ] **Step 4: 署名証明書作成スクリプトを作成**

`scripts/create-signing-cert.sh`（作成後 `chmod +x`）:

```bash
#!/usr/bin/env bash
# Creates a self-signed code signing identity in the login keychain so that
# rebuilt binaries keep the same designated requirement (and TCC permissions).
set -euo pipefail

NAME="mac-input-switcher-local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "Signing identity '$NAME' already exists."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOC
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOC

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -passout pass:temp -out "$TMP/identity.p12"

security import "$TMP/identity.p12" -k "$KEYCHAIN" -P temp -T /usr/bin/codesign
# Prompts for the login password to trust the certificate for code signing.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

security find-identity -v -p codesigning | grep "$NAME"
echo "Created signing identity '$NAME'."
```

- [ ] **Step 5: Makefile を作成**（レシピ行はタブでインデント）

`Makefile`:

```makefile
APP_NAME      := MacInputSwitcher
EXEC_NAME     := mac-input-switcher
BUNDLE_ID     := com.hiromaily.mac-input-switcher
SIGN_IDENTITY ?= mac-input-switcher-local

APP           := build/$(APP_NAME).app
INSTALL_DIR   := $(HOME)/Applications
INSTALLED_APP := $(INSTALL_DIR)/$(APP_NAME).app
AGENT_PLIST   := $(HOME)/Library/LaunchAgents/$(BUNDLE_ID).plist
LOG_FILE      := $(HOME)/Library/Logs/$(EXEC_NAME).log
USER_ID       := $(shell id -u)

.PHONY: test build sign install uninstall logs clean

test:
	swift test

build:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp .build/release/$(EXEC_NAME) $(APP)/Contents/MacOS/$(EXEC_NAME)

sign: build
	codesign --force --options runtime --sign "$(SIGN_IDENTITY)" $(APP)
	codesign --verify --strict --verbose=2 $(APP)

install: sign
	-launchctl bootout gui/$(USER_ID)/$(BUNDLE_ID) 2>/dev/null
	mkdir -p $(INSTALL_DIR) $(dir $(AGENT_PLIST)) $(dir $(LOG_FILE))
	rm -rf $(INSTALLED_APP)
	cp -R $(APP) $(INSTALLED_APP)
	sed -e "s|__APP_EXEC__|$(INSTALLED_APP)/Contents/MacOS/$(EXEC_NAME)|" \
	    -e "s|__LOG__|$(LOG_FILE)|" \
	    LaunchAgent/$(BUNDLE_ID).plist > $(AGENT_PLIST)
	launchctl bootstrap gui/$(USER_ID) $(AGENT_PLIST)
	@echo "Installed. Grant Input Monitoring and Accessibility to $(APP_NAME) if prompted."

uninstall:
	-launchctl bootout gui/$(USER_ID)/$(BUNDLE_ID) 2>/dev/null
	rm -f $(AGENT_PLIST)
	rm -rf $(INSTALLED_APP)

logs:
	tail -f $(LOG_FILE)

clean:
	rm -rf .build build
```

- [ ] **Step 6: .app のビルドを確認**

Run: `make build && plutil -p build/MacInputSwitcher.app/Contents/Info.plist | grep LSUIElement && file build/MacInputSwitcher.app/Contents/MacOS/mac-input-switcher`
Expected: `"LSUIElement" => true` と `Mach-O 64-bit executable arm64`

- [ ] **Step 7: 署名証明書を作成（ユーザー操作）**

ログインパスワードの入力ダイアログが出るため、ユーザー本人が実行する: `! scripts/create-signing-cert.sh`
Expected: 最後に `Created signing identity 'mac-input-switcher-local'.`（既存なら `already exists`）

- [ ] **Step 8: 署名を確認**

Run: `make sign && codesign -dv build/MacInputSwitcher.app 2>&1 | grep -E "Identifier|Authority"`
Expected: `Identifier=com.hiromaily.mac-input-switcher` と `Authority=mac-input-switcher-local`

- [ ] **Step 9: コミット**

```bash
git add Resources LaunchAgent scripts Makefile
git commit -m "build: add app bundling, signing, and LaunchAgent install"
```

---

### Task 5: インストール・実機確認・README・PR

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 4 の `make install` / `make uninstall` / `make logs`
- Produces: 常駐稼働しているツールと README

- [ ] **Step 1: README を作成**

`README.md`:

````markdown
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
````

- [ ] **Step 2: インストール**

Run: `make install`
Expected: `Installed. ...` が表示され、`launchctl print gui/$(id -u)/com.hiromaily.mac-input-switcher | grep state` が `state = running`（権限未付与なら再起動を繰り返す状態でもよい）

- [ ] **Step 3: 権限付与（ユーザー操作）**

ユーザーがシステム設定で「入力監視」「アクセシビリティ」に MacInputSwitcher を許可し、`launchctl kickstart -k gui/$(id -u)/com.hiromaily.mac-input-switcher` を実行。

Run: `tail -5 ~/Library/Logs/mac-input-switcher.log`
Expected: 最終行付近に `mac-input-switcher started`

- [ ] **Step 4: 手動テスト（ユーザー操作）**

README の「手動テスト」1〜4 をユーザーに実施してもらい、結果を確認する。項目 3 のため `make install` を再実行して権限が維持されることも確認。

- [ ] **Step 5: 最終確認**

Run: `make test`
Expected: 全テスト pass

- [ ] **Step 6: コミット・push・PR**

```bash
git add README.md
git commit -m "docs: add README with setup and manual test steps"
git push
```

PR は `gh pr create --base main` で作成（`gh` のアカウントがリポジトリのコラボレーターでない場合はブラウザで作成）。
