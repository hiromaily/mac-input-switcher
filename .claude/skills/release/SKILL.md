---
name: release
description: mac-input-switcher の新しいバージョンをリリースする。main でバージョンタグを打って push し、GitHub Actions の完了を待ち、公開されたファイルと最新リリースの URL を検証する。
disable-model-invocation: true
argument-hint: "[version, e.g. v0.2.3]"
---

# リリース

タグの push は公開操作です。各ステップの結果を確認しながら進め、想定と違ったらそこで止めてユーザーに報告してください。

## 1. main を最新にする

```bash
git switch main && git pull
git status --short   # 何も出ないこと
```

未コミットの変更があれば止めて、ユーザーに確認します。

## 2. テストを通す

```bash
make test
shellcheck install.sh scripts/test-install.sh
```

## 3. バージョンを決める

```bash
git tag -l 'v*' --sort=-v:refname | head -5
gh release list -R hiromaily/mac-input-switcher --limit 5
```

- 引数でバージョンが渡されていれば、それを使います
- 渡されていなければ、次のバージョンの候補を示してユーザーに確認します（修正なら patch、機能追加なら minor）
- 形式は `vX.Y.Z` です。`-` を含むタグ（`v1.0.0-rc1` など）はプレリリースとして公開されます

## 4. タグを打って push する

```bash
git tag -a vX.Y.Z -m "vX.Y.Z"
git push origin vX.Y.Z
```

## 5. ワークフローの完了を待つ

シェルの変数は Bash の呼び出しをまたいで残りません。以下のブロックは、それぞれ 1 回の呼び出しで実行してください。`SCRATCH` には、セッションの scratchpad ディレクトリのパスを書き込んでから実行します（未指定なら `mktemp -d` で作ります）。出力が長いので、ファイルに保存して末尾だけ読みます。完了まで数分かかるので、Bash ツールの `timeout` は 600000 にします。

```bash
SCRATCH="${SCRATCH:-$(mktemp -d)}"; TAG=vX.Y.Z
ID=""
for i in $(seq 1 30); do
  ID=$(gh run list -R hiromaily/mac-input-switcher --branch "$TAG" --event push --limit 1 --json databaseId -q '.[0].databaseId')
  [ -n "$ID" ] && break; sleep 2
done
[ -n "$ID" ] || { echo "run for $TAG not found"; exit 1; }
echo "run=$ID"
gh run watch "$ID" -R hiromaily/mac-input-switcher --exit-status > "$SCRATCH/release-run.log" 2>&1; echo "exit=$?"
tail -20 "$SCRATCH/release-run.log"
```

失敗したら、表示された `run=` の ID を使って `gh run view <ID> -R hiromaily/mac-input-switcher --log-failed` で原因を調べます。

## 6. 公開されたリリースを検証する

```bash
gh release view vX.Y.Z -R hiromaily/mac-input-switcher --json isPrerelease,assets \
  -q '"prerelease=" + (.isPrerelease|tostring) + " " + ([.assets[].name]|join(","))'
```

- `MacInputSwitcher.zip` と `MacInputSwitcher.zip.sha256` の 2 つが付いていること
- `prerelease` が、タグに `-` を含むかどうかと一致していること

通常のリリースなら、最新リリースの URL から取得して中身を確かめます。

作業ディレクトリをリポジトリの外に移さないよう、サブシェルの中で実行します。

```bash
SCRATCH="${SCRATCH:-$(mktemp -d)}"
(
  set -e
  D="$SCRATCH/release-check"; rm -rf "$D"; mkdir -p "$D"; cd "$D"
  URL=https://github.com/hiromaily/mac-input-switcher/releases/latest/download
  curl -fsSL -O "$URL/MacInputSwitcher.zip"
  curl -fsSL -O "$URL/MacInputSwitcher.zip.sha256"
  shasum -a 256 -c MacInputSwitcher.zip.sha256
  ditto -x -k MacInputSwitcher.zip u
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' u/MacInputSwitcher.app/Contents/Info.plist   # X.Y.Z であること
)
```

## 7. 手元のアプリを更新する（ユーザーの了承を得てから）

実環境を変えるので、実行してよいか先に確認します。

```bash
curl -fsSL https://raw.githubusercontent.com/hiromaily/mac-input-switcher/main/install.sh | bash
sleep 4; tail -n 2 ~/Library/Logs/mac-input-switcher.log   # 権限ダイアログなしで started になること
```

そのあと、左右の⌘で入力が切り替わるかをユーザーに確認してもらいます。

## 8. 報告する

リリースの URL、ワークフローの結果、検証結果、未確認の項目をユーザーに報告します。

失敗したリリースのタグを削除したり付け直したりするのは、公開済みの状態を変える操作です。必ずユーザーの了承を得てから行ってください。
