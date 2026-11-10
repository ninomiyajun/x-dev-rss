#!/usr/bin/env bash
# harness-copy: source=home/agents/skills/project-harness-init/assets/parts/node-harness/assets/stack-adapter.test.sh
# harness-copy: version=rules-2026.11.10-1
# harness-copy: sha256=27e3fdcbf281b7dd1d7936d5857a481283fb860a600905569571c85d977c8b00
# harness-copy: この 4 行と本体は手で変えない。正本を直して project-harness-init の「導入済みのプロジェクトの更新」で置き換える
# 段の読み取りの部品（stack-adapter.sh）の試験。部品 node-harness の写しで、手で変えない。
#   bash scripts/harness/stack-adapter.test.sh
# 一時ディレクトリに package.json だけの見本を作り、このファイルの置き場の stack-adapter.sh の写しを置いて動かす
# （プロジェクトの package.json と依存は使わない）。
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
check "stages は 0" 0 good stages
out_is "stages の出力" "$(printf 'SCRIPT\tlint\nSCRIPT\ttest\nSCRIPT\tcheck\nSTAGE\tlint\nSTAGE\ttest')"
check "run-stage は段の終了コード（0）" 0 good run-stage lint
check "run-stage は段の終了コード（3）" 3 good run-stage test
check "run-stage の段でない名前は 4" 4 good run-stage check
check "知らない働きは 4" 4 good other
sample broken '{'
check "読めない package.json は 3" 3 broken stages
sample nocheck '{"scripts":{"lint":"true"}}'
check "check が無ければ 4" 4 nocheck stages
sample badcheck '{"scripts":{"lint":"true","check":"npm run lint; npm run x"}}'
check "check の形の誤りは 5" 5 badcheck stages

echo "stack-adapter.test: 合格 $passed 件、不合格 $failed 件"
[ "$failed" -eq 0 ]
