# AI 向けドキュメント整備 設計

- 日付: 2026-10-09
- ステータス: レビュー待ち

## 背景と目的

このリポジトリには CLAUDE.md、`.claude/`（rules / skills / settings）がない。
目的は、新しいセッションの Claude Code が、変更・検証・リリースを安全に行えるようにすること。これまでのセッションで分かった前提や注意点を、毎回説明し直さなくて済むようにする。

対象は Claude Code のみとする（AGENTS.md や他ツール向けの設定は作らない）。

## 要件

- 新しいセッションでも、次の前提や注意点を説明なしで守れる
  - 署名用 ID と権限（TCC）の関係
  - 権限チェックの結果が、起動済みプロセスの中では更新されないこと
  - インストーラーのテストでは、実環境を触らないこと
  - bash 3.2 / 5.2 の両方に対応すること
  - PR とリリースの流れ
- **main ブランチで作業しない**ことを明記する
- 手順はスキルに、特定ファイル向けの注意は path-scoped rules に分け、CLAUDE.md は 200 行未満に保つ
- 実環境に影響する操作（権限のリセット、アンインストール、タグや push など）は、実行前に必ず確認を求める

## 非要件（YAGNI）

- AGENTS.md / Cursor / Copilot 向けの設定
- hooks（編集時の自動 shellcheck など）。必要になったら追加する
- README・既存 spec / plan の書き直し

## 前提とした Claude Code の仕様

公式ドキュメント（code.claude.com/docs の memory / skills / permissions / settings）を 2026-10-09 に確認した。

- `.claude/rules/*.md`: frontmatter の `paths`（glob のリスト）を書くと、該当ファイルを Read / Write / Edit したときだけ読み込まれる。`paths` がなければ起動時に常に読み込まれる
- `.claude/skills/<name>/SKILL.md`: frontmatter の `description` が呼び出し判断に使われる。`disable-model-invocation: true` にすると `/name` でしか呼べない
- `.claude/settings.json` の `permissions`: `deny` → `ask` → `allow` の順に評価され、最初に一致したものが適用される。Bash パターンは `Bash(cmd *)` 形式で書く。複合コマンドは、分割した各部分がすべて一致したときだけ許可される。セキュリティ境界ではない
- CLAUDE.md は 200 行未満が目安。`@path` でファイルを取り込める（取り込んだファイルも起動時に読み込まれる）

## 構成

```
CLAUDE.md
.claude/
├── settings.json
├── rules/
│   ├── installer.md
│   └── swift.md
└── skills/
    ├── release/SKILL.md
    └── verify-on-device/SKILL.md
```

## 各ファイルの内容

### CLAUDE.md（常に読み込まれる、100 行程度）

1. 概要
   - US キーボードで、左⌘の単独押しで英語入力、右⌘の単独押しで日本語入力に切り替える常駐ツール
   - listen-only の CGEventTap を使い、LaunchAgent で常駐する
   - 対象は macOS 15 以降 / Apple Silicon
2. コマンド
   - `make test`（Swift のテストと `scripts/test-install.sh`）
   - `make build VERSION=x.y.z`
   - `make install` / `make uninstall`（実環境に影響する）
   - `make logs`
   - `shellcheck install.sh scripts/test-install.sh`
3. 構成の地図
   - `Sources/InputSwitcherCore/`: macOS に依存しない判定ロジック。テスト対象
   - `Sources/mac-input-switcher/main.swift`: macOS API との境界
   - `install.sh`: `curl | bash` で使うインストーラー。`make install` / `make uninstall` もこれを呼ぶ
   - `scripts/test-install.sh`: インストーラーのテスト
   - `.github/workflows/release.yml`: リリース用ワークフロー
4. 壊してはいけない前提
   - 署名用 ID `mac-input-switcher-local` と Bundle ID `com.hiromaily.mac-input-switcher` は変えない。権限（TCC）は、署名から決まる ID に紐づいている
   - イベントは書き換えも破棄もしない
   - ユーザーの実環境（`~/Applications`、LaunchAgent、TCC、キーチェーン）を変える操作は、事前にユーザーの了承を得る
5. 作業の流れ
   - **main ブランチで直接作業・コミットしない。** 作業前に、最新の main から `feature/` / `fix/` / `chore/` / `docs/` のいずれかのブランチを切る
   - コミットメッセージは英語（Conventional Commits 形式）。README と PR 本文は日本語
   - PR 作成: `gh` のアカウント（`idom-hiroki-yasui`）はコラボレーターではないので、`gh pr create` は失敗する。ブランチを push し、比較用 URL と、貼り付けられる形のタイトル・本文をユーザーに渡す。ユーザーが `hiromaily` アカウントでブラウザから作成する
   - マージ後、ローカルのブランチを削除し、main を最新にする
   - リリースは `/release` を使う
   - 実機での確認は `verify-on-device` スキルの手順に従う
6. ドキュメント
   - `docs/superpowers/specs`・`plans` は作業時点の記録で、現状と異なる場合がある。現状の正はソースと README

### .claude/rules/installer.md

- `paths`: `install.sh`, `scripts/**`, `Makefile`, `.github/workflows/**`
- `curl | bash` で動かすための制約
  - 1 ファイルで完結させる
  - stdin を読まない
  - 処理はすべて関数の中に置き、最終行は `{ main "$@"; }` のままにする。こうしておくと、途中で途切れたダウンロードは構文エラーになり、何も実行されない
- bash 3.2（macOS 標準）と 5.2 の両方で動かす
  - 連想配列、`mapfile`、`${var,,}` を使わない
  - `set -u` のもとで空の配列を展開しない
  - `${var//pat/…&…}` を使わず、`sed` を使う（5.2 では置換後の `&` が一致した部分に展開される）
- テスト
  - `install.sh` を、実際の HOME やシステムコマンドに向けて実行しない
  - `scripts/test-install.sh` のスタブ（launchctl / tccutil / security / codesign / id）と、一時ディレクトリの HOME を使う
  - 失敗する経路や分岐を足したら、テストを先に書いて失敗を確認してから実装する
  - 確認は `scripts/test-install.sh`、`env PATH="/bin:/usr/bin:$PATH" scripts/test-install.sh`（bash 3.2）、`shellcheck` の 3 つで行う
- 変えると既存ユーザーの更新や権限が壊れるもの（変える場合は、移行方法を設計してから）
  - 署名用 ID 名
  - リリースのファイル名 `MacInputSwitcher.zip` / `.sha256`
  - インストール先のパス
  - LaunchAgent の Label
  - `MAC_INPUT_SWITCHER_VERSION`
- エラーメッセージはテストが部分一致で検証しているので、文言を変えるときはテストも直す
- ワークフロー
  - `make build VERSION=…` は、コマンドラインで渡す（Makefile は環境変数の `VERSION` を無視する）
  - `-` を含むタグはプレリリースとして公開される

### .claude/rules/swift.md

- `paths`: `Sources/**`, `Tests/**`, `Package.swift`
- macOS の API（CoreGraphics / ApplicationServices / Process など）を呼ぶのは `main.swift` だけにする。判定ロジックは `InputSwitcherCore` に置き、swift-testing でテストを先に書いて開発する
- Swift 6 言語モード、`platforms: [.macOS(.v15)]`、サードパーティへの依存なし、Xcode 不要（Command Line Tools のみ）
- イベントタップは listen-only。自分で合成したイベント（英数 / かな）は `eventSourceUserData` の目印で見分けて無視する
- 権限チェック（`CGPreflightListenEventAccess` / `AXIsProcessTrusted`）の結果は、起動済みプロセスの中では更新されない。待機中は `--check-permissions` の子プロセスで確認し、すべて許可されたら `execv` で再起動する
- ログの文言（`mac-input-switcher started`、`waiting for permissions: …`、`all permissions granted; restarting`）は README のトラブルシュートや確認手順が参照している。変えるときは README も直す
- `.build/release/mac-input-switcher` をターミナルから直接実行すると、権限を要求する主体がターミナルアプリになるので、動作確認には使わない

### .claude/skills/release/SKILL.md

- frontmatter: `description`（リリースを作成する手順）、`disable-model-invocation: true`、`argument-hint: "[version]"`
- 手順
  1. main に切り替え、`git pull`。作業ツリーがきれいなことを確認する
  2. `make test` と shellcheck を通す
  3. `git tag -l` / `gh release list` で現在のバージョンを確認し、次のバージョンをユーザーに確認する（引数があればそれを使う）
  4. `git tag -a vX.Y.Z -m vX.Y.Z` → `git push origin vX.Y.Z`
  5. `gh run list --branch vX.Y.Z` で実行 ID を取得し、`gh run watch <id> --exit-status` で完了を待つ。出力はファイルに保存して末尾だけ読む
  6. 次の 3 点を確認する
     - `gh release view vX.Y.Z --json isPrerelease,assets` で、ファイルが 2 つ付いていること
     - プレリリースかどうかが想定どおりであること
     - `releases/latest/download/MacInputSwitcher.zip` を取得して sha256 を検証し、Info.plist のバージョンが一致すること（プレリリースの場合は、この確認を省く）
  7. ユーザーの了承があれば、README のコマンドで手元のアプリを更新し、ログに `started` が出ることを確認する
  8. 結果をユーザーに報告する。失敗したら原因を調べ、タグの削除や付け直しはユーザーの了承を得てから行う

### .claude/skills/verify-on-device/SKILL.md

- frontmatter: `description`（実機でのインストール・権限・動作確認の手順。インストーラーや権限まわりの変更後に使う）
- 原則
  - 実環境を変える手順（`make install` / `make uninstall` / README のコマンド / `tccutil` / `launchctl kickstart`）は、どれを実行するかを示してユーザーの了承を得てから行う
  - `make uninstall` は TCC のエントリも消す。ユーザーは権限を付け直す必要がある
- 手順
  1. 確認したい内容に応じて、入れ方を選ぶ（手元のビルドなら `make install`、公開リリースなら README のコマンド）
  2. ログ `~/Library/Logs/mac-input-switcher.log` の末尾を確認する
  3. `waiting for permissions` が出ていれば、入力監視とアクセシビリティの許可をユーザーに依頼する。ログを 2 秒間隔で最大数分ポーリングし、`started` を待つ
  4. `started` になったら、左⌘ → 英語、右⌘ → 日本語の切り替えをユーザーに確認してもらう
  5. 再インストールで権限が維持されることを確かめる場合は、同じ手順でもう一度入れ、ダイアログが出ずに `started` になることを確認する
- ハマりどころ
  - TCC のデータベースは Full Disk Access がないと読めない。unified log でも詳細は伏せられている。判断はアプリのログで行う
  - ユーザーが ON にしたはずのアクセシビリティが OFF のままのことがある。進まないときは、システム設定での表示をユーザーに確認してもらう
  - 許可ダイアログを出し直すには `launchctl kickstart -k gui/$(id -u)/com.hiromaily.mac-input-switcher` を使う（起動時に 1 回だけ表示されるため）
  - 新しいプロセスでの判定を確かめたいときも `kickstart -k` を使う

### .claude/settings.json

```json
{
  "permissions": {
    "allow": [
      "Bash(make test)",
      "Bash(make build *)",
      "Bash(swift build *)",
      "Bash(swift test *)",
      "Bash(shellcheck *)",
      "Bash(scripts/test-install.sh)",
      "Bash(git status *)",
      "Bash(git diff *)",
      "Bash(git log *)",
      "Bash(gh run list *)",
      "Bash(gh run view *)",
      "Bash(gh run watch *)",
      "Bash(gh release view *)",
      "Bash(gh release list *)"
    ],
    "ask": [
      "Bash(make install)",
      "Bash(make uninstall)",
      "Bash(./install.sh *)",
      "Bash(tccutil *)",
      "Bash(security delete-identity *)",
      "Bash(launchctl *)",
      "Bash(git tag *)",
      "Bash(git push *)"
    ],
    "deny": [
      "Bash(git push --force *)",
      "Bash(git push -f *)"
    ]
  }
}
```

## 検証

- `python3 -m json.tool .claude/settings.json` が成功する
- 各 rule / skill の frontmatter が YAML として読める（`ruby -ryaml` で、`---` で囲まれた部分を読み込んで確認する）
- CLAUDE.md が 200 行未満
- 新しい Claude Code セッションで `/memory`（または起動時の読み込み）に CLAUDE.md と rules が出ていること、`/release` が補完に出ること、`install.sh` を Read したときに installer rule が読み込まれることを、ユーザーが確認する
