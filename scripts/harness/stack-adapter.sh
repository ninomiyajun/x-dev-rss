#!/usr/bin/env bash
# harness-copy: source=home/agents/skills/project-harness-init/assets/parts/node-harness/assets/stack-adapter.sh
# harness-copy: version=rules-2026.11.13-1
# harness-copy: sha256=2342052f26eb444daa43bea89df33a8bf331eadcacc52760add5e2ca81e6ea9e
# harness-copy: この 4 行と本体は手で変えない。正本を直して project-harness-init の「導入済みのプロジェクトの更新」で置き換える
# 段の読み取りの部品（node のプロジェクト）。ハーネスの検査の本体（scripts/harness/drift-scan.sh）が、技術ごとの違いを
# この口に任せる。部品 node-harness の写しで、手で変えない。
#
# 使い方:
#   stack-adapter.sh stages           package.json の scripts の名前を「SCRIPT<TAB>名前」、check に並ぶ段を「STAGE<TAB>名前」で出す。
#                                     check は「npm run <名前>」を && でつないだ形だけを受け取る。
#                                     終了コード: 0 / 3 package.json を読めない（scripts の名前に改行・タブ・CR があるときも、
#                                     行を偽れないよう何も出さずに 3）/ 4 scripts か check が無い / 5 check の形の誤り
#   stack-adapter.sh run-stage <名前>  段を 1 つ実行する（npm run --silent <名前>）。終了コードはその段のもの。
#                                     名前は stages が出した STAGE のどれかでなければ 4
#   stack-adapter.sh script <名前>     package.json の scripts の <名前> のコマンド（文字列）をそのまま 1 行で出す（実行しない）。
#                                     段でない名前も出す。部品が宣言した検査の段（part.tsv の check-stage）が一式の check に
#                                     宣言どおりの中身で並ぶかを、更新の道具（harness-copies.sh verify）が確かめるのに使う。
#                                     終了コード: 0 / 3 package.json を読めない（値に改行・タブ・CR があるときも、何も出さずに 3）/
#                                     4 引数の数の誤りか、その名前の文字列の値が無い
# 読むだけの口（stages・script と、run-stage の段の確かめ）は、PATH の node を、node の読み込みを変える環境変数（NODE_OPTIONS・
# NODE_PATH）を外して動かし、プロジェクトの依存（node_modules）を読まない（更新の道具の verify が、段の確かめに呼ぶため）。
# 作業ディレクトリに頼らず、このファイルの置き場からリポジトリの根を決める。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd -- "$ROOT"

read_stages() {
  [ -f package.json ] || return 3
  env -u NODE_OPTIONS -u NODE_PATH node -e '
    const fs = require("fs");
    let p;
    try { p = JSON.parse(fs.readFileSync("package.json", "utf8")); } catch { process.exit(3); }
    const s = p && p.scripts;
    if (!s || typeof s !== "object" || typeof s.check !== "string") process.exit(4);
    const out = [];
    for (const name of Object.keys(s)) {
      if (/[\t\n\r]/.test(name)) process.exit(3);
      out.push("SCRIPT\t" + name);
    }
    for (const part of s.check.split("&&")) {
      const m = /^npm run ([A-Za-z0-9:._-]+)$/.exec(part.trim());
      if (!m || !Object.prototype.hasOwnProperty.call(s, m[1]) || m[1] === "check") process.exit(5);
      out.push("STAGE\t" + m[1]);
    }
    process.stdout.write(out.join("\n") + "\n");
  '
}

case "${1:-}" in
  stages)
    [ "$#" -eq 1 ] || exit 4
    read_stages ;;
  run-stage)
    [ "$#" -eq 2 ] || exit 4
    stages="$(read_stages)" || exit 4
    printf '%s\n' "$stages" | grep -qxF -- "STAGE	$2" || exit 4
    exec npm run --silent "$2" ;;
  script)
    [ "$#" -eq 2 ] || exit 4
    [ -f package.json ] || exit 3
    env -u NODE_OPTIONS -u NODE_PATH node -e '
      const fs = require("fs");
      let p;
      try { p = JSON.parse(fs.readFileSync("package.json", "utf8")); } catch { process.exit(3); }
      const s = p && p.scripts;
      const n = process.argv[1];
      if (!s || typeof s !== "object" || !Object.prototype.hasOwnProperty.call(s, n) || typeof s[n] !== "string") process.exit(4);
      if (/[\t\n\r]/.test(s[n])) process.exit(3);
      process.stdout.write(s[n] + "\n");
    ' -- "$2" ;;
  *)
    echo "stack-adapter: 使い方: stack-adapter.sh stages | run-stage <名前> | script <名前>" >&2
    exit 4 ;;
esac
