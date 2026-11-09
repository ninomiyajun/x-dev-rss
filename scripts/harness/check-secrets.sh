#!/usr/bin/env bash
# harness-copy: source=home/agents/skills/project-harness-init/assets/parts/node-secrets/assets/check-secrets.sh
# harness-copy: version=rules-2026.11.08-1
# harness-copy: sha256=74fed15fd800b317cbc4eeaacb1cba57eb5bcb8e7a92dec3b96c0b10a499d043
# harness-copy: この 4 行と本体は手で変えない。正本を直して project-harness-init の「導入済みのプロジェクトの更新」で置き換える
# 秘匿値の検査の入口。本体は scripts/harness/check-secrets.mjs（調べる範囲と失敗にする条件はその冒頭）。
#   引数なし     作業ツリーの全ファイル（追跡済みと、.gitignore で除外していない未追跡）
#   --commits    push する範囲の各コミットに記録された中身とメッセージ（git fetch --prune origin の後に実行する）
#   --file <絶対パス>  そのファイル 1 つ（定期の走査が、報告を公開する前に使う。0 = 無し、1 = 有り、ほかは確かめられない）
# CI は本体を node で直接呼ぶ（npm の pre と post のスクリプトを動かさないため）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec node "$ROOT/scripts/harness/check-secrets.mjs" "$@"
