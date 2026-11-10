#!/usr/bin/env bash
# harness-copy: source=home/agents/skills/project-harness-init/assets/harness/drift-scan.test.sh
# harness-copy: version=rules-2026.11.10-1
# harness-copy: sha256=d97253af5a712b466f75b7fb1638be4ba4b4ec5d52ba9a5d8c955ff906628d96
# harness-copy: この 4 行と本体は手で変えない。正本を直して project-harness-init の「導入済みのプロジェクトの更新」で置き換える
# 定期の走査（drift-scan.sh）の試験。ハーネスの検査の本体の写しで、どのプロジェクトでも同じ中身を置く。
#   bash scripts/harness/drift-scan.test.sh
# 一時ディレクトリに見本のリポジトリを作り、このファイルの置き場の drift-scan.sh・check-docs.sh・harness.conf の写しと、
# 試験用の段の読み取りの部品（stack-adapter.sh）と秘匿値の検査（check-secrets.sh）の見本を置いて動かす。プロジェクトの
# 本物の部品と道具は動かさない（部品の試験は、部品の側の試験が受け持つ）。
# /bin/bash（macOS では 3.2）で動く書き方だけを使う。
set -euo pipefail
export LC_ALL=C
unset GITHUB_ACTIONS GITHUB_EVENT_NAME DRIFT_SCAN_RETENTION_DAYS DRIFT_SCAN_TEST_TODAY DRIFT_SCAN_TEST_STAGES GITHUB_BASE_REF HARNESS_BASE_REF

H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TMP_ROOT="$(mktemp -d)"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

TODAY="2026-03-10"
passed=0
failed=0
OUT=""
RC=0
REPORT=""

tgit() {
  git -c user.name=test -c user.email=test -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    -c init.defaultBranch=main -c core.fsmonitor=false "$@"
}

# 見本のリポジトリを作る。$1 = 置き場
new_sample() {
  local d="$1"
  mkdir -p "$d/scripts/harness" "$d/docs/exec-plans" "$d/.github/workflows" "$d/src"
  cp "$H/drift-scan.sh" "$H/check-docs.sh" "$d/scripts/harness/"
  # 設定は、走査が読むキーだけの最小の形（プロジェクトの設定の値に左右されないため）
  printf '%s\n' "format=1" "default_branch=main" > "$d/scripts/harness/harness.conf"
  # 段の読み取りの部品の見本: 段は lint と test。STAGE_FAIL に書いた段は終了コード 1 にする
  cat > "$d/scripts/harness/stack-adapter.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  stages) printf 'SCRIPT\tlint\nSCRIPT\ttest\nSCRIPT\tother\nSTAGE\tlint\nSTAGE\ttest\n' ;;
  run-stage) case " ${STAGE_FAIL:-} " in *" $2 "*) exit 1 ;; esac; exit 0 ;;
  *) exit 4 ;;
esac
EOF
  # 秘匿値の検査の見本: --file のファイルに「SECRET-VALUE」があれば 1
  cat > "$d/scripts/harness/check-secrets.sh" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--file" ] || exit 2
[ -z "${SECRETS_STUB_RC:-}" ] || exit "$SECRETS_STUB_RC"
if grep -q 'SECRET-VALUE' "$2"; then exit 1; fi
exit 0
EOF
  printf '%s\n' "# 見本" "" "ハーネスの版: 1" "" "## 文書の地図" "" "| 種類 | パス |" "|---|---|" \
    '| 品質目標 | `docs/QUALITY_SCORE.md` |' '| 技術的負債の一覧 | `docs/exec-plans/tech-debt-tracker.md` |' > "$d/AGENTS.md"
  printf '%s\n' "# 品質目標" "" "## 目標" "" "| 目標 | 測る項目 | 確かめ方 | 検査の識別子 |" "|---|---|---|---|" \
    '| 壊れない | 試験 | 試験を流す | `test` |' "" "## 現在の評価" "" "見直しの目安: 90 日" "" \
    "| 領域 | 評価 | 検査の識別子 | 根拠 | 評価した日 | 評価したコミット |" "|---|---|---|---|---|---|" \
    '| 全体 | B | `lint`, `test` | 見本 | 2026-03-01 | abcdef1 |' > "$d/docs/QUALITY_SCORE.md"
  printf '%s\n' "# 技術的負債の一覧" "" "## 一覧" "" "| 識別子 | 見つけた日 | 場所 | 内容 | 見つけた作業 |" "|---|---|---|---|---|" \
    '| TD-1 | 2026-03-01 | `src/a.txt` | 見本 | 見本 |' > "$d/docs/exec-plans/tech-debt-tracker.md"
  printf 'a\n' > "$d/src/a.txt"
  printf '%s\n' "# 間隔の日数: 7" "on:" "  schedule:" '    - cron: "23 0 * * 1"' > "$d/.github/workflows/drift-scan.yml"
  tgit -C "$d" init -q
  tgit -C "$d" add -A
  tgit -C "$d" commit -q -m "見本"
  tgit -C "$d" update-ref refs/remotes/origin/main HEAD
}

# 走査を 1 回動かす。$1 = 見本、$2 以降 = 環境変数（名前=値）
run_scan() {
  local d="$1"
  shift
  rm -rf "$TMP_ROOT/out"
  set +e
  OUT="$(cd "$d" && env DRIFT_SCAN_TEST_TODAY="$TODAY" "$@" bash scripts/harness/drift-scan.sh --out "$TMP_ROOT/out" 2>&1)"
  RC=$?
  set -e
  REPORT="$TMP_ROOT/out/report.md"
}

expect() {
  local name="$1"
  shift
  if "$@"; then
    echo "ok: $name"
    passed=$((passed + 1))
  else
    echo "NG: ${name}（成り立たない: $*）" >&2
    echo "    終了コード: $RC" >&2
    printf '%s\n' "$OUT" | sed 's/^/    出力: /' >&2
    [ -f "$REPORT" ] && sed 's/^/    報告: /' "$REPORT" >&2
    failed=$((failed + 1))
  fi
}
rc_is() { [ "$RC" -eq "$1" ]; }
report_has() { [ -f "$REPORT" ] && grep -qF -- "$1" "$REPORT"; }
out_has() { grep -qF -- "$1" <<<"$OUT"; }
no_report() { [ ! -e "$REPORT" ]; }
not() { ! "$@"; }

# 1. 通常の走査
S="$TMP_ROOT/s1"
new_sample "$S"
run_scan "$S"
expect "1: 報告を書いて 0 で終わる" rc_is 0
expect "1: 段ごとの行がある" report_has '| `1/lint` | 0 |'
expect "1: 文書の鮮度の行がある" report_has '`2/docs/QUALITY_SCORE.md`'
expect "1: 技術的負債の行がある" report_has '`3/TD-1`'
expect "1: 品質目標の行がある" report_has '`4/領域:全体`'
expect "1: 試験の差し替えを要対応にする" report_has '| `5/試験の差し替え` | あり | 要対応 |'

# 2. 段の失敗と、評価 B の照合
run_scan "$S" STAGE_FAIL=test
expect "2: 失敗した段を要対応にする" report_has '| `1/test` | 1 |'
expect "2: 評価が B なのに段が失敗した行を要対応にする" report_has "評価が B なのに識別子の段が失敗した"
run_scan "$S" "DRIFT_SCAN_TEST_STAGES=lint=0 test=2"
expect "2: 試験の差し替えの終了コードを使う" report_has '| `1/test` | 2 | 0 |'

# 3. 表を列の名前で読む（列が足されていてもよい。層の表は省ける）
S="$TMP_ROOT/s3"
new_sample "$S"
printf '%s\n' "" "| 層 | 評価 | 検査の識別子 | 人が確かめる決まりの数 | 根拠 | 評価した日 | 評価したコミット |" "|---|---|---|---|---|---|---|" \
  '| ui | A | `lint` | 2 | 見本 | 2026-03-02 | abcdef2 |' >> "$S/docs/QUALITY_SCORE.md"
run_scan "$S"
expect "3: 列の多い層の表も読む" report_has '`4/層:ui`'
no_table_error() { ! grep -qF '| `4/表`' "$REPORT"; }
expect "3: 表の書式の誤りは無い" no_table_error
S="$TMP_ROOT/s3b"
new_sample "$S"
sed 's/| 評価した日 |/| 日 |/' "$S/docs/QUALITY_SCORE.md" > "$S/q.tmp"
mv "$S/q.tmp" "$S/docs/QUALITY_SCORE.md"
run_scan "$S"
expect "3: 要る列の無い表は 4/表 を要対応にする" report_has "「評価」「検査の識別子」「評価した日」の列のどれかが無い"

# 4. 場所のファイルが無い技術的負債
rm -f "$TMP_ROOT/s3/src/a.txt"
run_scan "$TMP_ROOT/s3"
expect "4: 場所のファイルが無い行を要対応にする" report_has '| `3/TD-1` | `src/a.txt` | 9 | 無い |'

# 5. 続けられない場合（終了コード 2）
S="$TMP_ROOT/s5"
new_sample "$S"
rm -f "$S/scripts/harness/stack-adapter.sh"
run_scan "$S"
expect "5: 段の読み取りの部品が無ければ 2" rc_is 2
expect "5: 部品が無いと決まった文面で知らせる" out_has "段の読み取りの部品（harness-stack）がありません"
S="$TMP_ROOT/s5b"
new_sample "$S"
rm -f "$S/scripts/harness/check-secrets.sh"
run_scan "$S"
expect "5: 秘匿値の検査の部品が無ければ 2" rc_is 2
expect "5: 秘匿値の検査が無いと決まった文面で知らせる" out_has "秘匿値の検査の部品（secrets-check）がありません"
S="$TMP_ROOT/s5c"
new_sample "$S"
sed 's/^# 間隔の日数: 7$/# 間隔の日数: 1/' "$S/.github/workflows/drift-scan.yml" > "$S/w.tmp"
mv "$S/w.tmp" "$S/.github/workflows/drift-scan.yml"
run_scan "$S"
expect "5: 注釈の間隔と cron が合わなければ 2" rc_is 2
run_scan "$TMP_ROOT/s1" GITHUB_ACTIONS=true
expect "5: CI の中の試験の差し替えは 2" rc_is 2
mkdir -p "$TMP_ROOT/out"
: > "$TMP_ROOT/out/x"
set +e
OUT="$(cd "$TMP_ROOT/s1" && env DRIFT_SCAN_TEST_TODAY="$TODAY" bash scripts/harness/drift-scan.sh --out "$TMP_ROOT/out" 2>&1)"
RC=$?
set -e
expect "5: --out が空でなければ 2" rc_is 2

# 6. 公開してよいかの検査（終了コード 3、報告を残さない）
S="$TMP_ROOT/s6"
new_sample "$S"
printf '%s\n' '| TD-2 | 2026-03-01 | `SECRET-VALUE` | 見本 | 見本 |' >> "$S/docs/exec-plans/tech-debt-tracker.md"
run_scan "$S"
expect "6: 秘匿値の検査に当たれば 3" rc_is 3
expect "6: 当たった形だけを知らせる" out_has "秘匿値の検査の規則に当たる値"
expect "6: 報告を残さない" no_report
run_scan "$TMP_ROOT/s1" SECRETS_STUB_RC=2
expect "6: 秘匿値の検査が動かなければ（終了コード 2）、走査は 2" rc_is 2
expect "6: 秘匿値の検査が動かないと決まった文面で知らせる" out_has "秘匿値の検査が動きませんでした（終了コード 2）"
expect "6: 秘匿値の検査が動かないときも報告を残さない" no_report
S="$TMP_ROOT/s6b"
new_sample "$S"
printf '%s\n' "format=1" "default_branch=-main" > "$S/scripts/harness/harness.conf"
run_scan "$S"
expect "6: default_branch が - で始まれば 2" rc_is 2

# 7. 走査は文書の検査の --print arch-path-re を使い、正規表現の写しを持たない
no_copy_re() { ! grep -qF 'src|docs|scripts' "$H/drift-scan.sh"; }
expect "7: drift-scan.sh に検査 7 の正規表現の写しが無い" no_copy_re
expect "7: drift-scan.sh は --print arch-path-re を呼ぶ" grep -qF -- '--print arch-path-re' "$H/drift-scan.sh"

# 8. 表の終わり（GFM と同じく、空行か別の塊の始まりで表が終わる。表の直後の縦線で始まらない行は表の続きなので誤り）
TABLE_CONT="表の行が縦線で始まらない（表は空行で終える）"
td_error() { grep -qF '| `3/表`' "$REPORT"; }
qs_error() { grep -qF '| `4/表`' "$REPORT"; }
no_td_error() { ! td_error; }
# $1 = 見本の名前、$2 以降 = 技術的負債の一覧の表の直後に足す行
td_after() {
  S="$TMP_ROOT/$1"
  shift
  new_sample "$S"
  printf '%s\n' "$@" >> "$S/docs/exec-plans/tech-debt-tracker.md"
  run_scan "$S"
}
# $1 = 見本の名前、$2 以降 = 品質目標の「現在の評価」の表の直後に足す行
qs_after() {
  S="$TMP_ROOT/$1"
  shift
  new_sample "$S"
  printf '%s\n' "$@" >> "$S/docs/QUALITY_SCORE.md"
  run_scan "$S"
}
td_after s8a 'TD-2 | 2026-03-01 | `src/a.txt` | 見本 | 見本 |'
expect "8: 縦線の無い TD-2 の行は、3/表 に理由を出す" report_has "8 行: $TABLE_CONT"
expect "8: 縦線の無い行を、技術的負債の行として読まない" not report_has '`3/TD-2`'
qs_after s8b "表の直後に空行を挟まない段落"
expect "8: 品質目標の表の直後に空行なしの段落があれば、4/表 を要対応にする" qs_error
expect "8: 品質目標の表の直後の段落の理由を出す" report_has "$TABLE_CONT"
qs_after s8c "" "表の後に空行を挟んだ段落"
expect "8: 表・空行・段落の順なら、4/表 は出ない" no_table_error
td_after s8d "" "表の後に空行を挟んだ段落"
expect "8: 表・空行・段落の順なら、3/表 は出ない" no_td_error
td_after s8e "#hashtag の行"
expect "8: #hashtag の行は見出しでないので、表の続きとして誤りにする" report_has "8 行: $TABLE_CONT"
td_after s8f "<https://example.test>"
expect "8: 自動リンクの行は HTML ブロックでないので、表の続きとして誤りにする" report_has "8 行: $TABLE_CONT"
td_after s8g "### 補足" "見出しの後の段落"
expect "8: 本物の見出しで表が終わる" no_td_error
td_after s8h "<div>" "HTML ブロックの中" "</div>"
expect "8: HTML ブロック（決まった名前のタグ）で表が終わる" no_td_error
td_after s8i "<!-- 注釈 -->"
expect "8: HTML ブロック（<!-- ）で表が終わる" no_td_error
td_after s8j "- 箇条書き" "1. 順序付きの箇条書き"
expect "8: 箇条書きで表が終わる" no_td_error
td_after s8k "---" "区切り線の後の段落"
expect "8: 区切り線で表が終わる" no_td_error
td_after s8l '   | TD-2 | 2026-03-01 | `src/a.txt` | 見本 | 見本 |'
expect "8: 行頭の空白が 3 個までの縦線の行は、表の行として読む" report_has '`3/TD-2`'
expect "8: 行頭の空白が 3 個までの縦線の行では、誤りにしない" no_td_error
# 情報文字列にバッククォートを含む ``` の行は囲みの開始ではなく、小文字の <!doctype は HTML の宣言ではない（表が続く）
TD2_BARE='TD-2 | 2026-03-01 | `src/a.txt` | 見本 | 見本 |'
td_after s8n '```bad`info' "$TD2_BARE"
expect "8: 情報文字列にバッククォートを含む行の後も表が続き、3/表 に誤りが出る" report_has "9 行: $TABLE_CONT"
td_after s8o '<!doctype html>' "$TD2_BARE"
expect "8: 小文字の <!doctype の行の後も表が続き、3/表 に誤りが出る" report_has "9 行: $TABLE_CONT"
qs_after s8p '```bad`info' "$TD2_BARE"
expect "8: 品質目標でも、情報文字列にバッククォートを含む行の後に表が続き、4/表 に誤りが出る" report_has "17 行: $TABLE_CONT"
qs_after s8q '<!doctype html>' "$TD2_BARE"
expect "8: 品質目標でも、小文字の <!doctype の行の後に表が続き、4/表 に誤りが出る" report_has "17 行: $TABLE_CONT"
td_after s8r '```info' "$TD2_BARE" '```'
expect "8: 正しい囲み（\`\`\`info）で表が終わる" no_td_error
td_after s8s '<!DOCTYPE html>' "$TD2_BARE"
expect "8: HTML の宣言（<!DOCTYPE）で表が終わる" no_td_error
qs_after s8t '~~~info`x' "$TD2_BARE" '~~~'
expect "8: チルダの囲みは情報文字列にバッククォートがあっても表を終える" no_table_error
S="$TMP_ROOT/s8m"
new_sample "$S"
# 「見直しの目安」の行を、目標の表の直後に空行を挟まずに置く
awk '/^見直しの目安:/ { next } { print } /^\| 壊れない/ { print "見直しの目安: 90 日" }' "$S/docs/QUALITY_SCORE.md" > "$S/q.tmp"
mv "$S/q.tmp" "$S/docs/QUALITY_SCORE.md"
run_scan "$S"
expect "8: 表の直後に空行なしで続く「見直しの目安」の行は、表を終えずに誤りにする" report_has "8 行: $TABLE_CONT"

echo "drift-scan.test: 合格 $passed 件、不合格 $failed 件"
[ "$failed" -eq 0 ]
