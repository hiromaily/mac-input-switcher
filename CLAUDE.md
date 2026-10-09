# mac-input-switcher

US キーボードで、左⌘の単独押しで英語入力、右⌘の単独押しで日本語入力に切り替える macOS 常駐ツール。
listen-only の CGEventTap で⌘キーを監視し、JIS の英数 / かなキーを合成して入力ソースを切り替える。`.app`（`LSUIElement`）を LaunchAgent で常駐させる。

- 対象: macOS 15 以降 / Apple Silicon（arm64）のみ
- 言語・ツール: Swift 6（Command Line Tools のみ、Xcode 不要）、bash、make、GitHub Actions
- 依存: サードパーティなし

## コマンド

| コマンド | 内容 |
|---|---|
| `make test` | Swift のテスト + `scripts/test-install.sh`（インストーラーのテスト） |
| `shellcheck install.sh scripts/test-install.sh` | シェルスクリプトの lint |
| `make build VERSION=x.y.z` | `build/MacInputSwitcher.app` を作る（`VERSION` を省略すると `0.0.0-dev`） |
| `make install` / `make uninstall` | 手元のビルドをインストール / 削除する。**ユーザーの実環境を変える** |
| `make logs` | `~/Library/Logs/mac-input-switcher.log` を追う |

## 構成

- `Sources/InputSwitcherCore/` — macOS に依存しない判定ロジック（単独押しの判定、イベントの変換、権限待ちの判断）。ここをテストする
- `Sources/mac-input-switcher/main.swift` — macOS API との境界（イベントタップ、権限チェック、キーの合成）
- `Tests/InputSwitcherCoreTests/` — swift-testing のテスト
- `install.sh` — `curl | bash` で使うインストーラー。`make install` / `make uninstall` もこれを呼ぶ
- `scripts/test-install.sh` — インストーラーのテスト（システムコマンドはスタブに置き換える）
- `.github/workflows/release.yml` — `v*` タグの push でビルドし、Releases に公開する
- `Resources/Info.plist` — `__BUNDLE_ID__` / `__VERSION__` はビルド時に置換される

ファイルごとの注意は `.claude/rules/` にあり、該当するファイルを開くと読み込まれる。

## 壊してはいけない前提

- 署名用 ID `mac-input-switcher-local` と Bundle ID `com.hiromaily.mac-input-switcher` を変えない。入力監視・アクセシビリティの許可（TCC）は署名から決まる ID に紐づいており、変えると既存ユーザーの権限が更新時に外れる
- キーイベントは書き換えも破棄もしない（listen-only）
- ユーザーの実環境（`~/Applications`、LaunchAgent、TCC、ログインキーチェーン）を変える操作は、何をするかを示して了承を得てから行う。テストから実環境に触れない

## 作業の流れ

- **main ブランチで直接作業・コミットしない。** 作業を始める前に `git switch main && git pull` を実行し、`feature/`・`fix/`・`chore/`・`docs/` のいずれかで始まるブランチを切る
- 新機能や挙動の変更は、spec（`docs/superpowers/specs/`）と plan（`docs/superpowers/plans/`）を書いてから実装する。小さな修正は、会話で設計を合意してから実装する
- テストを先に書き、失敗することを確認してから実装する
- コミットメッセージは英語の Conventional Commits（`feat:` / `fix:` / `docs:` / `chore:` / `ci:` / `build:`）。README と PR 本文は日本語
- PR: `gh` のログインアカウント（`idom-hiroki-yasui`）はこのリポジトリのコラボレーターではないため、`gh pr create` は失敗する。ブランチを push したら、`https://github.com/hiromaily/mac-input-switcher/compare/main...<branch>` と、そのまま貼れるタイトル・本文をユーザーに渡す。ユーザーが `hiromaily` アカウントでブラウザから作成・マージする
- マージ後: `git switch main && git pull` を実行し、マージ済みのローカルブランチを `git branch -d` で削除する
- リリース: `/release`（`.claude/skills/release/`）
- 実機での確認: `verify-on-device` スキル（`.claude/skills/verify-on-device/`）

## ドキュメント

- `README.md` — 利用者向け（インストール・トラブルシュート）と開発者向け
- `docs/superpowers/specs/`・`plans/` — 作業時点の設計と計画の記録。現状と異なる箇所がある。現状を正しく表すのはソースと README
