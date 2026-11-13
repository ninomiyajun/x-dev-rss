#!/usr/bin/env bash
# harness-copy: source=home/agents/skills/project-harness-init/assets/parts/node-harness/assets/stack-adapter.test.sh
# harness-copy: version=rules-2026.11.13-1
# harness-copy: sha256=6ee34324ecd209905ec39aa709dc241ea6b52c7926c1d8cdbf750d67327d0743
# harness-copy: この 4 行と本体は手で変えない。正本を直して project-harness-init の「導入済みのプロジェクトの更新」で置き換える
# 段の読み取りの部品（stack-adapter.sh）の試験。部品 node-harness の写しで、手で変えない。
#   bash scripts/harness/stack-adapter.test.sh
# 一時ディレクトリに package.json だけの見本を作り、このファイルの置き場の stack-adapter.sh の写しを置いて動かす
# （プロジェクトの package.json と依存は使わない）。
# 見本の名前の決まり: 口（stack-adapter.sh の最初の引数）の見本は「口 <口の名前>: <説明>」で始める。部品の宣言
# （part.tsv の provides-port）の口ごとに、この形の見本が 1 つ以上あることを、敷設の手順の定義の確かめが求める。
set -euo pipefail
export LC_ALL=C
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
passed=0
failed=0

# 見本を作る。$1 = 名前、$2 = package.json の中身
sample() {
  mkdir -p "$TMP_ROOT/$1/scripts/harness"
  cp "$H/stack-adapter.sh" "$TMP_ROOT/$1/scripts/harness/"
  printf '%s\n' "$2" > "$TMP_ROOT/$1/package.json"
}
# $1 = 名前、$2 = 期待する終了コード、$3 = 見本、$4 以降 = 引数
check() {
  local name="$1" want="$2" s="$3" rc=0
  shift 3
  ( cd "$TMP_ROOT" && bash "$TMP_ROOT/$s/scripts/harness/stack-adapter.sh" "$@" ) > "$TMP_ROOT/out" 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ]; then echo "ok: $name"; passed=$((passed + 1)); else
    echo "NG: ${name}（終了コード ${rc}、期待 ${want}）" >&2; sed 's/^/    /' "$TMP_ROOT/out" >&2; failed=$((failed + 1)); fi
}
out_is() {
  if [ "$(cat "$TMP_ROOT/out")" = "$2" ]; then echo "ok: $1"; passed=$((passed + 1)); else
    echo "NG: $1" >&2; sed 's/^/    /' "$TMP_ROOT/out" >&2; failed=$((failed + 1)); fi
}

sample good '{"scripts":{"lint":"node -e \"process.exit(0)\"","test":"node -e \"process.exit(3)\"","check":"npm run lint && npm run test"}}'
check "口 stages: 0" 0 good stages
out_is "口 stages: 出力" "$(printf 'SCRIPT\tlint\nSCRIPT\ttest\nSCRIPT\tcheck\nSTAGE\tlint\nSTAGE\ttest')"
check "口 run-stage: 段の終了コード（0）" 0 good run-stage lint
check "口 run-stage: 段の終了コード（3）" 3 good run-stage test
check "口 run-stage: 段でない名前は 4" 4 good run-stage check
check "口 script: 0" 0 good script lint
out_is "口 script: 出力は、その名前のコマンドの 1 行" 'node -e "process.exit(0)"'
check "口 script: 段でない名前（check）も出す" 0 good script check
out_is "口 script: check のコマンド" 'npm run lint && npm run test'
check "口 script: 無い名前は 4" 4 good script nope
check "口 script: 引数の数の誤りは 4" 4 good script
check "口 script: - で始まる名前も、node の設定ではなく名前として読む（無ければ 4）" 4 good script --version
check "知らない口は 4" 4 good other
NODE_OPTIONS="--require=$TMP_ROOT/no-such-preload.js" check "口 stages: NODE_OPTIONS の読み込みを使わない（読むだけの口）" 0 good stages
NODE_OPTIONS="--require=$TMP_ROOT/no-such-preload.js" check "口 script: NODE_OPTIONS の読み込みを使わない（読むだけの口）" 0 good script lint
sample broken '{'
check "口 stages: 読めない package.json は 3" 3 broken stages
check "口 script: 読めない package.json は 3" 3 broken script lint
sample nocheck '{"scripts":{"lint":"true"}}'
check "口 stages: check が無ければ 4" 4 nocheck stages
check "口 script: check が無くても、ある名前は出す" 0 nocheck script lint
out_is "口 script: check の無い見本の出力" 'true'
sample notstring '{"scripts":{"x":1,"check":"npm run x"}}'
check "口 script: 文字列でない値は 4" 4 notstring script x
sample proto '{"scripts":{"lint":"true"}}'
check "口 script: scripts の持ち物でない名前（toString）は 4" 4 proto script toString
sample protostage '{"scripts":{"lint":"true","check":"npm run lint && npm run constructor"}}'
check "口 stages: scripts の持ち物でない名前（constructor）を段にした check は形の誤りの 5" 5 protostage stages
# 名前に改行とタブを入れて、偽の STAGE の行を出させようとする見本（check には lint しか並んでいない）
sample forged '{"scripts":{"lint":"true","check":"npm run lint","check:x":"true","y\nSTAGE\tcheck:x":"true"}}'
check "口 stages: 名前に改行かタブがあれば、何も出さずに 3（偽の行を出さない）" 3 forged stages
out_is "口 stages: 名前に改行かタブがあるときの出力は空" ''
check "口 script: 改行かタブのある名前の見本でも、ほかの名前は出す" 0 forged script lint
sample badvalue '{"scripts":{"lint":"true\nSTAGE\tx","tab":"a\tb","check":"npm run lint"}}'
check "口 script: 値に改行があれば、何も出さずに 3" 3 badvalue script lint
out_is "口 script: 値に改行があるときの出力は空" ''
check "口 script: 値にタブがあれば 3" 3 badvalue script tab

echo "stack-adapter.test: 合格 $passed 件、不合格 $failed 件"
[ "$failed" -eq 0 ]
