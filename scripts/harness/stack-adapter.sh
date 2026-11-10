#!/usr/bin/env bash
# harness-copy: source=home/agents/skills/project-harness-init/assets/parts/node-harness/assets/stack-adapter.sh
# harness-copy: version=rules-2026.11.10-1
# harness-copy: sha256=80f773ce0c533bf6dbf9b8faeadc79fbc28c548683e789a042f8ccd2d61662ca
# harness-copy: この 4 行と本体は手で変えない。正本を直して project-harness-init の「導入済みのプロジェクトの更新」で置き換える
# 段の読み取りの部品（node のプロジェクト）。ハーネスの検査の本体（scripts/harness/drift-scan.sh）が、技術ごとの違いを
# この口に任せる。部品 node-harness の写しで、手で変えない。
#
# 使い方:
#   stack-adapter.sh stages           package.json の scripts の名前を「SCRIPT<TAB>名前」、check に並ぶ段を「STAGE<TAB>名前」で出す。
#                                     check は「npm run <名前>」を && でつないだ形だけを受け取る。
#                                     終了コード: 0 / 3 package.json を読めない / 4 scripts か check が無い / 5 check の形の誤り
#   stack-adapter.sh run-stage <名前>  段を 1 つ実行する（npm run --silent <名前>）。終了コードはその段のもの。
#                                     名前は stages が出した STAGE のどれかでなければ 4
# 作業ディレクトリに頼らず、このファイルの置き場からリポジトリの根を決める。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd -- "$ROOT"

read_stages() {
  [ -f package.json ] || return 3
  node -e '
    const fs = require("fs");
    let p;
    try { p = JSON.parse(fs.readFileSync("package.json", "utf8")); } catch { process.exit(3); }
    const s = p && p.scripts;
    if (!s || typeof s !== "object" || typeof s.check !== "string") process.exit(4);
    const out = [];
    for (const name of Object.keys(s)) out.push("SCRIPT\t" + name);
    for (const part of s.check.split("&&")) {
      const m = /^npm run ([A-Za-z0-9:._-]+)$/.exec(part.trim());
      if (!m || !(m[1] in s) || m[1] === "check") process.exit(5);
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
  *)
    echo "stack-adapter: 使い方: stack-adapter.sh stages | run-stage <名前>" >&2
    exit 4 ;;
esac
