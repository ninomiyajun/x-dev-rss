#!/usr/bin/env bash
# harness-copy: source=home/agents/skills/project-harness-init/assets/harness/check-docs.test.sh
# harness-copy: version=rules-2026.11.08-1
# harness-copy: sha256=4fb84b424c8e7664145c41f53d907b3a7dc825a736b2a92b7b7101f934bc24e6
# harness-copy: この 4 行と本体は手で変えない。正本を直して project-harness-init の「導入済みのプロジェクトの更新」で置き換える
# check-docs.sh の試験（検査 8〜13、設定のファイル、追加の検査の口）。ハーネスの検査の本体の写しで、どのプロジェクトでも
# 同じ中身を置く。手元で使うコマンドは下の TEST_COMMAND（CI はこのスクリプトを bash で直接呼ぶ）。最後に、このファイルの
# 置き場の checks.d/ の *.test.sh（プロジェクト専用の検査の試験）を順に流し、1 つでも失敗すれば、この試験を失敗にする。
#
# 場合ごとに、一時ディレクトリに小さなリポジトリ（git init だけ。検査 12 の場合だけコミットする）を作り、check-docs.sh と
# harness.conf の写しと、本物の docs/PLANS.md の写し（製品の仕様の置き場があるときは、本物の docs/product-specs/README.md の
# 写しも）を置いて、計画・記録・仕様の組を変えて動かす。終了コードと、失敗のときは理由の文言を確かめる。
# 検査は、基準の日（HARNESS_TODAY）を決まった日にし、分岐元の環境変数（GITHUB_BASE_REF、HARNESS_BASE_REF）を外して動かす。
# 計画・記録・仕様の見本はこのファイルの中で作り、リポジトリに Markdown の見本を置かない（検査 4、8、10 が見本を拾うため）。
# 見本の題材は、プロジェクトの実際の機能と関係の無い架空の機能（一覧の文字の大きさの切り替え）にする。
# 製品の仕様の置き場（docs/product-specs/README.md）が無いプロジェクトでは、検査 10 の試験のうち、置き場が無い場合の
# 試験だけを動かす（置き場がある場合の試験は、本物の書式の文書を写して見本を作るため）。
set -euo pipefail
export LC_ALL=C

TEST_COMMAND="bash scripts/harness/check-docs.test.sh"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SELF/../.." && pwd)"
CHECK="$SELF/check-docs.sh"
CONF="$SELF/harness.conf"
PLANS="$ROOT/docs/PLANS.md"
SPECS_README="$ROOT/docs/product-specs/README.md"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# 新しい書式の適用開始の日付を、本物の docs/PLANS.md から読む（日付を試験に二重に持たないため）
START="$(sed -n 's/^新しい書式の適用開始: \([0-9-]*\)$/\1/p' "$PLANS" | head -n 1)"
if [ -z "$START" ]; then
  echo "check-docs.test: NG: $PLANS から「新しい書式の適用開始」の日付を読み取れません" >&2
  exit 1
fi
NEW="$START-list-font-size"   # 新しい書式の計画の名前（適用開始の当日）
OLD="2000-01-01-old-plan"   # 旧い書式の計画の名前
# 検査 11（古い計画）の基準の日の既定。新しい書式の適用開始の日（計画の名前の日付と同じ）
BASE_TODAY="$START"
CASE_TODAY=""
CASE_ENV=()   # 次の run_case の 1 回だけに足す環境変数（「名前=値」の並び）

# 版 1 の必須のファイルの一覧を、設定のファイル harness.conf の required.1 から読む（一覧を試験に二重に持たないため）
REQUIRED="$(sed -n 's/^required\.1=//p' "$CONF" 2>/dev/null || true)"
if [ -z "$REQUIRED" ]; then
  echo "check-docs.test: NG: $CONF から版 1 の必須のファイルの一覧（required.1）を読み取れません" >&2
  exit 1
fi
# 必須のファイルの一覧は見本の中にファイルを作るのに使うので、書き込む前に根からの相対のパスかを確かめる
while IFS= read -r p; do
  case "$p" in
    /*|..|../*|*/..|*/../*)
      echo "check-docs.test: NG: required.1 の「${p}」が、根からの相対のパス（/ で始まらず、.. を含まない）ではありません" >&2
      exit 1 ;;
  esac
done <<EOF
$REQUIRED
EOF
# 製品の仕様の置き場が必須のファイルにあるか（あれば、置き場が無い場合の試験は作れない）
SPEC_REQUIRED=0
grep -qxF 'docs/product-specs/README.md' <<<"$REQUIRED" && SPEC_REQUIRED=1
SPEC_PRESENT=0
[ -f "$SPECS_README" ] && SPEC_PRESENT=1

passed=0
failed=0
skipped=0

SP="docs/product-specs"

# 仕様の置き場を作り、本物の docs/product-specs/README.md の書式（目録の節より前）と、目録の表の見出しの 2 行を写す。
# 目録の表の本文の行（実際に登録された仕様）は取り除き、空の目録にする。残すと、実際に仕様が登録されたとき、
# 写した先にその仕様のファイルが無く、通るはずの試験が失敗するため。README.md がリンクする
# 製品の前提（docs/PRODUCT_SENSE.md）も写す（検査 4 のリンクの検査を通すため）
add_spec_dir() {
  mkdir -p "$1/$SP"
  awk '/^## 目録$/ { in_catalog = 1 } !(in_catalog && /^\| / && !/^\| 略号 /)' "$SPECS_README" > "$1/$SP/README.md"
  if [ -f "$ROOT/docs/PRODUCT_SENSE.md" ]; then
    cp "$ROOT/docs/PRODUCT_SENSE.md" "$1/docs/PRODUCT_SENSE.md"
  fi
}

# 検査 1〜7 を通る最小のリポジトリを作る。必須のファイルは、決まった中身が要るものを除いて空のファイルにする。
# 中身は試験の間に変わらない値（REQUIRED、PLANS、CHECK、CONF、SPEC_REQUIRED など）だけで決まるので、最初の 1 回だけ
# 作って git init したひな形（BASE_TEMPLATE）を、場合ごとに cp -R で写す（場合ごとに作り直して git init すると遅いため）
build_base() {
  local d="$1" p
  mkdir -p "$d/docs/exec-plans/active" "$d/docs/exec-plans/completed"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$p" in
      */) mkdir -p "$d/$p" ;;
      AGENTS.md)
        printf '%s\n' "# 試験" "" "ハーネスの版: 1" "" "## 文書の地図" "" "| 種類 | パス |" "|---|---|" "| 計画の書式 | \`docs/PLANS.md\` |" > "$d/AGENTS.md" ;;
      CLAUDE.md) printf '@AGENTS.md\n' > "$d/CLAUDE.md" ;;
      ARCHITECTURE.md) printf '# ARCHITECTURE\n' > "$d/ARCHITECTURE.md" ;;
      docs/adr/README.md) mkdir -p "$d/docs/adr"; printf '# ADR\n' > "$d/docs/adr/README.md" ;;
      docs/PLANS.md) mkdir -p "$d/docs"; cp "$PLANS" "$d/docs/PLANS.md" ;;
      docs/product-specs/README.md|docs/PRODUCT_SENSE.md) ;;   # 下の add_spec_dir で置く
      *) mkdir -p "$(dirname "$d/$p")"; : > "$d/$p" ;;
    esac
  done <<EOF
$REQUIRED
EOF
  mkdir -p "$d/scripts/harness"
  cp "$CHECK" "$d/scripts/harness/check-docs.sh"
  cp "$CONF" "$d/scripts/harness/harness.conf"
  [ -f "$d/docs/PLANS.md" ] || { mkdir -p "$d/docs"; cp "$PLANS" "$d/docs/PLANS.md"; }
  if [ "$SPEC_REQUIRED" -eq 1 ]; then
    add_spec_dir "$d"
  elif grep -qxF 'docs/PRODUCT_SENSE.md' <<<"$REQUIRED"; then
    : > "$d/docs/PRODUCT_SENSE.md"
  fi
  git -C "$d" init -q
}
BASE_TEMPLATE="$TMP_ROOT/base-template"
build_base "$BASE_TEMPLATE"
# ひな形を $1（まだ無いパス）に写す
make_base() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    echo "check-docs.test: NG: 見本の置き場 $1 が既にあります（ひな形を写す先は、まだ無いパスにする）" >&2
    exit 1
  fi
  cp -R "$BASE_TEMPLATE" "$1"
}

# 書式の文書（$1）の「## 必須の節」から、必須の見出しを 1 行ずつ出す
required_headings() {
  awk '/^## 必須の節$/{on=1; next} /^## /{on=0} on' "$1" | sed -n 's/^[0-9][0-9]*\. `\(## [^`]*\)`.*$/\1/p'
}

# 計画を書く。$1 = パス、$2 = 検証の節の本文、$3 = 目的の節の本文（省略可）、$4 = 進捗の節の本文（省略時は、基準の日の
# 既定の日付の 1 行。検査 11 の対象でない場合の進行中の計画が古い計画にならないようにするため。空の文字列を渡すと、
# 進捗の節を空にする）。必須の節の見出しは本物の docs/PLANS.md から読む
write_plan() {
  local path="$1" verification="$2" purpose="${3:-}" progress="${4-- $BASE_TODAY: 試験の進捗。}" heading
  {
    printf '# 試験の計画\n\n'
    required_headings "$PLANS" | while IFS= read -r heading; do
      printf '%s\n\n' "$heading"
      if [ "$heading" = "## 検証（完了の条件）" ]; then
        printf '%s\n\n' "$verification"
      elif [ "$heading" = "## 目的" ] && [ -n "$purpose" ]; then
        printf '%s\n\n' "$purpose"
      elif [ "$heading" = "## 進捗" ] && [ -n "$progress" ]; then
        printf '%s\n\n' "$progress"
      fi
    done
  } > "$path"
}

# 受け入れ確認の基準 2 件（V1、V2）と、自動テストの基準 1 件（V3）を持つ、新しい書式の検証の節
VERIFY_NEW='### V1 文字の大きさを「大」にすると、一覧の文字が大きくなる

- 前提: 一覧が標準の文字の大きさで表示されている。
- 操作: 文字の大きさの切り替えで「大」を選ぶ。
- 期待する結果: 一覧の各項目の題が、標準より大きい文字で表示される。
- 確かめ方: 受け入れ確認

### V2 選んだ文字の大きさが、開き直した後も残る

- 前提: 同上。
- 操作: 「大」を選んだ後、一覧を開き直す。
- 期待する結果: 一覧の各項目の題が、大きい文字のまま表示される。
- 確かめ方: 受け入れ確認

### V3 大きさの値を読む関数が、知らない値を標準に戻す

- 確かめ方: 自動テスト'

# 記録の 1 回分の実行（docs/PLANS.md の「受け入れ確認の記録」の必須の行をすべて持つ）。
# $1 = 番号、$2 = 確かめた者、$3 以降 = 「識別子=結果」。全体の値は、結果がすべて合格なら合格、そうでなければ不合格
run_block() {
  local n="$1" who="$2" pair overall="合格"
  shift 2
  printf '## 実行 %s\n\n- 日時: 2030-01-15 14:05（日本時間）\n- 確かめた者: %s\n- 元のコミット: 1111111\n- 分岐元: 0000000\n' "$n" "$who"
  printf -- '- 確かめた対象:\n  - `src/list/view.ext` 2222222 変更なし\n'
  for pair in "$@"; do
    printf -- '- 基準 %s: %s\n  - 前提: 試験の前提\n  - 操作: 試験の操作\n  - 観察した結果: 試験の値\n  - 証拠: 試験の証拠\n' \
      "${pair%%=*}" "${pair#*=}"
    [ "${pair#*=}" = "合格" ] || overall="不合格"
  done
  printf -- '- 基準外の所見: なし\n- 未確認の範囲: なし\n- 全体: %s\n\n' "$overall"
}

# 正しい記録（実行 1 で V1 と V2 が合格）から、$2 で始まる行を 1 行だけ消したものを $1 に書く
record_without_line() {
  run_block 1 app-evaluator V1=合格 V2=合格 | awk -v prefix="$2" '!done && index($0, prefix) == 1 { done = 1; next } { print }' > "$1"
}

# 場合を 1 つ動かす。$1 = 名前、$2 = 期待（pass / fail）、$3 = 失敗のときに出力に含まれるべき文言、$4 = 準備の関数
run_case() {
  local name="$1" expect="$2" want="$3" setup="$4" d out rc
  d="$TMP_ROOT/case-$((passed + failed + 1))"
  make_base "$d"
  "$setup" "$d"
  set +e
  out="$(env -u GITHUB_BASE_REF -u HARNESS_BASE_REF ${CASE_ENV[@]+"${CASE_ENV[@]}"} HARNESS_TODAY="${CASE_TODAY:-$BASE_TODAY}" \
    bash "$d/scripts/harness/check-docs.sh" 2>&1)"
  rc=$?
  set -e
  CASE_ENV=()
  if [ "$expect" = pass ] && [ "$rc" -eq 0 ]; then
    echo "ok: ${name}（通る）"
    passed=$((passed + 1))
  elif [ "$expect" = fail ] && [ "$rc" -eq 1 ] && grep -qF -- "$want" <<<"$out"; then
    echo "ok: ${name}（失敗する: ${want}）"
    passed=$((passed + 1))
  else
    echo "NG: ${name}（期待: ${expect}、終了コード: ${rc}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    failed=$((failed + 1))
  fi
}

# 基準の日を指定して、場合を 1 つ動かす。$1 = 基準の日（YYYY-MM-DD）、$2 以降 = run_case の引数
run_case_on() {
  CASE_TODAY="$1"
  shift
  run_case "$@"
  CASE_TODAY=""
}

# 条件 $1 が 1 のときだけ場合を動かす（このプロジェクトに当てはまらない場合を数えずに飛ばす）
run_case_if() {
  local cond="$1"
  shift
  if [ "$cond" -eq 1 ]; then
    run_case "$@"
  else
    skipped=$((skipped + 1))
  fi
}
# 置き場が無い場合の試験は、仕様の置き場が必須のファイルに無いときだけ作れる
NODIR_OK=$((1 - SPEC_REQUIRED))

C="docs/exec-plans/completed"
A="docs/exec-plans/active"

# --- 通る場合 ---

setup_empty() { :; }

setup_correct() {
  write_plan "$1/$C/$NEW.md" "$VERIFY_NEW"
  run_block 1 app-evaluator V1=合格 V2=合格 > "$1/$C/$NEW.acceptance.md"
}

setup_partial_recheck() {
  write_plan "$1/$C/$NEW.md" "$VERIFY_NEW"
  { run_block 1 app-evaluator V1=不合格 V2=合格; run_block 2 app-evaluator V1=合格; } > "$1/$C/$NEW.acceptance.md"
}

setup_other_checker_later() {
  write_plan "$1/$C/$NEW.md" "$VERIFY_NEW"
  { run_block 1 app-evaluator V1=合格 V2=合格; run_block 2 implementer V1=不合格 V2=未確認; } > "$1/$C/$NEW.acceptance.md"
}

setup_active_pair() {
  write_plan "$1/$A/$NEW.md" "$VERIFY_NEW"
  # 進行中の計画の記録は合否を検査しない（不合格のままでも通る）。記録を計画とみなさないことも確かめる
  run_block 1 app-evaluator V1=不合格 V2=未確認 > "$1/$A/$NEW.acceptance.md"
}

setup_old_format() {
  write_plan "$1/$C/$OLD.md" "$VERIFY_NEW"
}

setup_criteria_in_code_block() {
  write_plan "$1/$C/$NEW.md" '### V3 自動テストだけの基準

- 確かめ方: 自動テスト

```markdown
### V1 例として書いた受け入れ確認の基準
- 確かめ方: 受け入れ確認
```'
}

# --- 失敗する場合 ---

setup_no_record() {
  write_plan "$1/$C/$NEW.md" "$VERIFY_NEW"
}

setup_latest_failed() {
  write_plan "$1/$C/$NEW.md" "$VERIFY_NEW"
  { run_block 1 app-evaluator V1=合格 V2=合格; run_block 2 app-evaluator V2=不合格; } > "$1/$C/$NEW.acceptance.md"
}

setup_latest_unverified() {
  write_plan "$1/$C/$NEW.md" "$VERIFY_NEW"
  { run_block 1 app-evaluator V1=合格 V2=合格; run_block 2 app-evaluator V1=未確認; } > "$1/$C/$NEW.acceptance.md"
}

setup_only_other_checker() {
  write_plan "$1/$C/$NEW.md" "$VERIFY_NEW"
  { run_block 1 app-evaluator V1=合格; run_block 2 implementer V2=合格; } > "$1/$C/$NEW.acceptance.md"
}

setup_record_only() {
  run_block 1 app-evaluator V1=合格 > "$1/$C/$NEW.acceptance.md"
}

setup_misplaced() {
  write_plan "$1/$C/$NEW.md" "$VERIFY_NEW"
  run_block 1 app-evaluator V1=合格 V2=合格 > "$1/$A/$NEW.acceptance.md"
}

setup_fake_pass_in_code_block() {
  write_plan "$1/$C/$NEW.md" "$VERIFY_NEW"
  {
    run_block 1 app-evaluator V1=合格 V2=不合格
    printf '## 実行 2\n\n```markdown\n- 確かめた者: app-evaluator\n- 基準 V2: 合格\n```\n'
  } > "$1/$C/$NEW.acceptance.md"
}

setup_outside_heading() {
  write_plan "$1/$C/$NEW.md" '- 確かめ方: 受け入れ確認

### V1 文字の大きさを「大」にすると、一覧の文字が大きくなる

- 確かめ方: 受け入れ確認'
  run_block 1 app-evaluator V1=合格 > "$1/$C/$NEW.acceptance.md"
}

# 記録に書いてはならない絶対パスの見本。この試験のファイル自身に絶対パスの文字を残さないため、実行時に組み立てる
SEP="/"
SAMPLE_ABS_PATH="${SEP}private${SEP}tmp${SEP}shot.png"
setup_absolute_path() {
  write_plan "$1/$C/$NEW.md" "$VERIFY_NEW"
  {
    run_block 1 app-evaluator V1=合格 V2=合格
    printf -- '- 証拠: スクリーンショット %s\n' "$SAMPLE_ABS_PATH"
  } > "$1/$C/$NEW.acceptance.md"
}

VERIFY_V2_OK='### V2 選んだ文字の大きさが、開き直した後も残る

- 確かめ方: 自動テスト'

setup_fullwidth_colon() {
  write_plan "$1/$C/$NEW.md" "### V1 題

- 確かめ方：受け入れ確認

$VERIFY_V2_OK"
}

setup_other_bullet() {
  write_plan "$1/$C/$NEW.md" "### V1 題

* 確かめ方: 受け入れ確認

$VERIFY_V2_OK"
}

setup_missing_method() {
  write_plan "$1/$C/$NEW.md" "### V1 題

- 期待する結果: 並ぶ。

$VERIFY_V2_OK"
}

setup_two_methods() {
  write_plan "$1/$C/$NEW.md" "### V1 題

- 確かめ方: 自動テスト
- 確かめ方: 人が確認"
}

setup_bad_method_value() {
  write_plan "$1/$C/$NEW.md" "### V1 題

- 確かめ方: 目で見る"
}

setup_duplicate_id() {
  write_plan "$1/$C/$NEW.md" "### V1 題

- 確かめ方: 自動テスト

### V1 別の題

- 確かめ方: 人が確認"
}

setup_unclosed_code_block_plan() {
  write_plan "$1/$C/$NEW.md" "$VERIFY_V2_OK

\`\`\`text
閉じていない"
}

setup_no_headings() {
  write_plan "$1/$C/$NEW.md" "基準はまだ書いていない。"
}

setup_table_row_acceptance() {
  write_plan "$1/$C/$NEW.md" "$VERIFY_V2_OK

| 基準 | 確かめる手段 |
|---|---|
| V1 | 受け入れ確認 |"
}

setup_method_without_colon() {
  write_plan "$1/$C/$NEW.md" "### V1 題

- 確かめ方 受け入れ確認

$VERIFY_V2_OK"
}

# 地の文と、ほかの項目の行で受け入れ確認に触れるだけなら通る
setup_prose_mentions_acceptance() {
  write_plan "$1/$C/$NEW.md" "受け入れ確認は、この計画では使わない。

### V1 題

- 期待する結果: 受け入れ確認の担当が見ても分かる表示になる。
- 確かめ方: 自動テスト"
}

setup_heading_without_id() {
  write_plan "$1/$C/$NEW.md" "###

- 確かめ方: 自動テスト"
}

setup_indented_method() {
  write_plan "$1/$C/$NEW.md" "### V1 題

  - 確かめ方: 自動テスト"
}

setup_skipped_run_number() {
  write_plan "$1/$C/$NEW.md" "$VERIFY_NEW"
  { run_block 1 app-evaluator V1=合格 V2=合格; run_block 3 app-evaluator V1=合格; } > "$1/$C/$NEW.acceptance.md"
}

setup_non_run_heading() {
  write_plan "$1/$C/$NEW.md" "$VERIFY_NEW"
  { run_block 1 app-evaluator V1=合格 V2=合格; printf '## メモ\n\n- 追記\n'; } > "$1/$C/$NEW.acceptance.md"
}

setup_bad_overall() {
  write_plan "$1/$C/$NEW.md" "$VERIFY_NEW"
  run_block 1 app-evaluator V1=合格 V2=合格 | sed 's/^- 全体: 合格$/- 全体: おおむね合格/' > "$1/$C/$NEW.acceptance.md"
}

setup_empty_required_value() {
  write_plan "$1/$C/$NEW.md" "$VERIFY_NEW"
  run_block 1 app-evaluator V1=合格 V2=合格 | sed 's/^- 日時: .*$/- 日時:/' > "$1/$C/$NEW.acceptance.md"
}

MISSING_PREFIX=""
setup_record_missing_line() {
  write_plan "$1/$C/$NEW.md" "$VERIFY_NEW"
  record_without_line "$1/$C/$NEW.acceptance.md" "$MISSING_PREFIX"
}

setup_duplicate_run_number() {
  write_plan "$1/$C/$NEW.md" "$VERIFY_NEW"
  { run_block 1 app-evaluator V1=合格 V2=合格; run_block 1 app-evaluator V1=合格; } > "$1/$C/$NEW.acceptance.md"
}

setup_reversed_run_number() {
  write_plan "$1/$C/$NEW.md" "$VERIFY_NEW"
  { run_block 2 app-evaluator V1=合格 V2=合格; run_block 1 app-evaluator V1=合格; } > "$1/$C/$NEW.acceptance.md"
}

setup_unclosed_code_block_record() {
  write_plan "$1/$C/$NEW.md" "$VERIFY_NEW"
  { run_block 1 app-evaluator V1=合格 V2=合格; printf '```text\n閉じていない\n'; } > "$1/$C/$NEW.acceptance.md"
}

setup_undated_completed_plan() {
  write_plan "$1/$C/list-font-size.md" "$VERIFY_NEW"
}

setup_misplaced_reverse() {
  write_plan "$1/$A/$NEW.md" "$VERIFY_NEW"
  run_block 1 app-evaluator V1=合格 V2=合格 > "$1/$C/$NEW.acceptance.md"
}

setup_no_start_line() {
  grep -v '^新しい書式の適用開始: ' "$1/docs/PLANS.md" > "$1/docs/PLANS.md.tmp"
  mv "$1/docs/PLANS.md.tmp" "$1/docs/PLANS.md"
}

run_case "計画も記録も無い" pass "" setup_empty
run_case "正しい記録" pass "" setup_correct
run_case "部分の再確認（実行 2 で V1 だけを確かめ直して合格）" pass "" setup_partial_recheck
run_case "app-evaluator 以外の実行が後にあっても、判定に数える最新が合格" pass "" setup_other_checker_later
run_case "active/ に計画と記録がある（検査 9 の対象外。記録を計画とみなさない）" pass "" setup_active_pair
run_case "旧い書式の完了した計画（記録が無くてよい）" pass "" setup_old_format
run_case "計画のコードブロックの中の受け入れ確認の基準は数えない" pass "" setup_criteria_in_code_block

run_case "記録が無い" fail "受け入れ確認の記録 $C/$NEW.acceptance.md がありません" setup_no_record
run_case "最新が不合格" fail "基準 V2 の、最新の受け入れ確認の結果が「不合格」" setup_latest_failed
run_case "最新が未確認（前の実行は合格）" fail "基準 V1 の、最新の受け入れ確認の結果が「未確認」" setup_latest_unverified
run_case "app-evaluator 以外の実行しか無い基準" fail "基準 V2 に、判定に数える受け入れ確認の実行がありません" setup_only_other_checker
run_case "記録だけがある" fail "に対応する計画 $C/$NEW.md がありません" setup_record_only
run_case "置き場の取り違え（計画は completed/、記録は active/）" fail "と別のディレクトリにあります" setup_misplaced
run_case "コードブロックの中にだけ偽の合格の行がある記録" fail "基準 V2 の、最新の受け入れ確認の結果が「不合格」" setup_fake_pass_in_code_block
run_case "見出しの外に受け入れ確認の基準がある新しい計画" fail "どの「### <識別子>」の見出しの下にも無い" setup_outside_heading
run_case "記録に絶対パス" fail "に絶対パスの形があります" setup_absolute_path
run_case "確かめ方の行に全角のコロン" fail "形の崩れた確かめ方の行があります" setup_fullwidth_colon
run_case "確かめ方の行に別の箇条書きの記号" fail "形の崩れた確かめ方の行があります" setup_other_bullet
run_case "基準に確かめ方の行が無い" fail "基準 V1 に「- 確かめ方: <値>」の行がありません" setup_missing_method
run_case "基準に確かめ方の行が 2 行" fail "基準 V1 に「- 確かめ方: <値>」の行が 2 行あります" setup_two_methods
run_case "確かめ方の値が 3 つのどれでもない" fail "「自動テスト」「受け入れ確認」「人が確認」のどれでもありません" setup_bad_method_value
run_case "基準の識別子の重複" fail "基準の識別子 V1 が重複しています" setup_duplicate_id
run_case "地の文とほかの項目の行で受け入れ確認に触れるだけの計画" pass "" setup_prose_mentions_acceptance
run_case "検証の節に基準の見出しが 1 つも無い" fail "基準の見出し（### <識別子> <題>）が 1 つもありません" setup_no_headings
run_case "表の行に受け入れ確認" fail "表の行に受け入れ確認があります" setup_table_row_acceptance
run_case "コロンの無い確かめ方の行" fail "形の崩れた確かめ方の行があります" setup_method_without_colon
run_case "識別子の無い見出し" fail "識別子の無い基準の見出しがあります" setup_heading_without_id
run_case "字下げした確かめ方の行" fail "形の崩れた確かめ方の行があります" setup_indented_method
run_case "実行の番号の欠け（1 の次が 3）" fail "2 番目の実行の番号が 3 です" setup_skipped_run_number
run_case "「## 実行 <番号>」でない ## の見出し" fail "「## 実行 <番号>」でない見出しがあります" setup_non_run_heading
run_case "全体の値が 3 種のどれでもない" fail "全体の値「おおむね合格」は、合格・不合格・未確認のどれでもありません" setup_bad_overall
run_case "値の無い必須の行" fail "実行 1 の「- 日時:」に値がありません" setup_empty_required_value
run_case "計画に閉じていないコードブロック" fail "閉じていないコードブロック" setup_unclosed_code_block_plan
for field in 日時 確かめた者 元のコミット 分岐元 確かめた対象 基準外の所見 未確認の範囲 全体; do
  MISSING_PREFIX="- $field:"
  run_case "記録の実行に「- $field:」の行が無い" fail "実行 1 に「- $field:」の行がありません" setup_record_missing_line
done
MISSING_PREFIX="  - 証拠:"
run_case "記録の基準の下に証拠の行が無い" fail "実行 1 の基準 V1 の下に「  - 証拠: <値>」の行がありません" setup_record_missing_line
run_case "実行の番号の重複" fail "2 番目の実行の番号が 1 です" setup_duplicate_run_number
run_case "実行の番号の逆順" fail "1 番目の実行の番号が 2 です" setup_reversed_run_number
run_case "記録に閉じていないコードブロック" fail "閉じていないコードブロック" setup_unclosed_code_block_record
run_case "日付で始まらない名前の完了した計画（検査 9 の対象）" fail "受け入れ確認の記録 $C/list-font-size.acceptance.md がありません" setup_undated_completed_plan
run_case "置き場の取り違えの逆向き（計画は active/、記録は completed/）" fail "と別のディレクトリにあります" setup_misplaced_reverse
run_case "docs/PLANS.md に適用開始の行が無い" fail "「新しい書式の適用開始: YYYY-MM-DD」の行がありません" setup_no_start_line

# --- 検査 10: 製品の仕様 ---

# 目録に 1 行を足す。$1 = リポジトリ、$2 = 略号、$3 = 仕様のファイル名、$4 = 状態。
# 目録の節はファイルの最後にある（書式の文書の決まり）ので、末尾に足せば表の行になる
add_catalog_row() {
  printf '| %s | [%s](%s) | 文字の大きさの切り替え | %s |\n' "$2" "$3" "$3" "$4" >> "$1/$SP/README.md"
}

# 受け入れ基準 1 件。$1 = 識別子
criterion() {
  printf '### %s 文字の大きさを「大」にすると、一覧の文字が大きくなる\n\n- 前提: 一覧が標準の文字の大きさで表示されている。\n- 操作: 文字の大きさの切り替えで「大」を選ぶ。\n- 期待する結果: 一覧の各項目の題が、標準より大きい文字で表示される。\n' "$1"
}

# 仕様を書く。$1 = パス、$2 = 受け入れ基準の節の本文、$3 = 未決の点の節の本文（省略時は「なし」）。
# 必須の節の見出しは本物の docs/product-specs/README.md から読む
write_spec() {
  local path="$1" criteria="$2" open="${3:-なし}" heading
  {
    printf '# 一覧の文字の大きさの切り替え\n\n'
    required_headings "$SPECS_README" | while IFS= read -r heading; do
      printf '%s\n\n' "$heading"
      case "$heading" in
        "## 受け入れ基準") printf '%s\n\n' "$criteria" ;;
        "## 未決の点") printf '%s\n\n' "$open" ;;
        *) printf '試験の本文。\n\n' ;;
      esac
    done
  } > "$path"
}

# 正しい仕様 1 件（略号 FONT、基準 FONT-1 と FONT-2）を、状態 $2 で置く
add_font_spec() {
  add_spec_dir "$1"
  write_spec "$1/$SP/list-font-size.md" "$(criterion FONT-1)

$(criterion FONT-2)"
  add_catalog_row "$1" FONT list-font-size.md "$2"
}

# 仕様の基準 FONT-1 と、計画の中で振る基準 V1 を引く検証の節（確かめ方は自動テストなので、受け入れ確認の記録は要らない）
VERIFY_SPEC='### FONT-1 文字の大きさを「大」にすると、一覧の文字が大きくなる

- 前提: 仕様のとおり。
- 操作: 仕様のとおり。
- 期待する結果: 仕様のとおり。
- 確かめ方: 自動テスト

### V1 切り替えの部品の試験が通る

- 確かめ方: 自動テスト'
PURPOSE_SPEC='一覧の文字の大きさを切り替えられるようにする。製品の仕様: `docs/product-specs/list-font-size.md`'
PURPOSE_NONE='一覧の文字の大きさを切り替えられるようにする。製品の仕様は無い。'
VERIFY_V_ONLY='### V1 切り替えの部品の試験が通る

- 確かめ方: 自動テスト'

# --- 検査 10: 通る場合 ---

setup_spec_correct() { add_font_spec "$1" draft; }
setup_spec_catalog_empty() { add_spec_dir "$1"; }
setup_spec_no_dir_v_only() {
  write_plan "$1/$A/$NEW.md" "$VERIFY_V_ONLY" "$PURPOSE_NONE"
  write_plan "$1/$C/$NEW-done.md" "$VERIFY_V_ONLY" "$PURPOSE_NONE"
}
setup_spec_active_approved() {
  add_font_spec "$1" approved
  write_plan "$1/$A/$NEW.md" "$VERIFY_SPEC" "$PURPOSE_SPEC"
}
setup_spec_completed_approved() {
  add_font_spec "$1" approved
  write_plan "$1/$C/$NEW.md" "$VERIFY_SPEC" "$PURPOSE_SPEC"
}
setup_spec_completed_archived() {
  add_font_spec "$1" archived
  write_plan "$1/$C/$NEW.md" "$VERIFY_SPEC" "$PURPOSE_SPEC"
}
setup_spec_draft_open_question() {
  add_spec_dir "$1"
  write_spec "$1/$SP/list-font-size.md" "$(criterion FONT-1)" '- [NEEDS CLARIFICATION: 文字の大きさの段階は 2 つか 3 つか]'
  add_catalog_row "$1" FONT list-font-size.md draft
}
# 旧い書式の計画は、仕様と照合しない
setup_spec_old_plan_ignored() {
  write_plan "$1/$C/$OLD.md" "$VERIFY_SPEC" "$PURPOSE_NONE"
}

# --- 検査 10: 失敗する場合 ---

setup_spec_not_in_catalog() {
  add_spec_dir "$1"
  write_spec "$1/$SP/list-font-size.md" "$(criterion FONT-1)"
}
setup_spec_missing_file() {
  add_spec_dir "$1"
  add_catalog_row "$1" FONT list-font-size.md draft
}
setup_spec_bad_status() { add_font_spec "$1" done; }
setup_spec_status_line() {
  add_font_spec "$1" draft
  printf '状態: draft\n' >> "$1/$SP/list-font-size.md"
}
setup_spec_approved_open_question() {
  add_spec_dir "$1"
  write_spec "$1/$SP/list-font-size.md" "$(criterion FONT-1)" '- [NEEDS CLARIFICATION: 文字の大きさの段階は 2 つか 3 つか]'
  add_catalog_row "$1" FONT list-font-size.md approved
}
setup_spec_missing_section() {
  add_font_spec "$1" draft
  grep -vxF '## 利用者の操作の流れ' "$1/$SP/list-font-size.md" > "$1/$SP/tmp" && mv "$1/$SP/tmp" "$1/$SP/list-font-size.md"
}
setup_spec_bad_abbr() {
  add_spec_dir "$1"
  write_spec "$1/$SP/list-font-size.md" "$(criterion Font-1)"
  add_catalog_row "$1" Font list-font-size.md draft
}
setup_spec_duplicate_abbr() {
  add_font_spec "$1" draft
  write_spec "$1/$SP/list-font-color.md" "$(criterion FONT-3)"
  add_catalog_row "$1" FONT list-font-color.md draft
}
setup_spec_duplicate_id() {
  add_spec_dir "$1"
  write_spec "$1/$SP/list-font-size.md" "$(criterion FONT-1)

$(criterion FONT-1)"
  add_catalog_row "$1" FONT list-font-size.md draft
}
setup_spec_id_abbr_mismatch() {
  add_spec_dir "$1"
  write_spec "$1/$SP/list-font-size.md" "$(criterion SIZE-1)"
  add_catalog_row "$1" FONT list-font-size.md draft
}
setup_spec_missing_item() {
  add_spec_dir "$1"
  write_spec "$1/$SP/list-font-size.md" "$(criterion FONT-1 | grep -v '^- 操作:')"
  add_catalog_row "$1" FONT list-font-size.md draft
}
setup_spec_no_criteria() {
  add_spec_dir "$1"
  write_spec "$1/$SP/list-font-size.md" "基準はまだ書いていない。"
  add_catalog_row "$1" FONT list-font-size.md draft
}
setup_spec_criteria_only_in_code_block() {
  add_spec_dir "$1"
  write_spec "$1/$SP/list-font-size.md" "\`\`\`markdown
$(criterion FONT-1)
\`\`\`"
  add_catalog_row "$1" FONT list-font-size.md draft
}
setup_plan_unknown_spec_id() {
  add_font_spec "$1" approved
  write_plan "$1/$A/$NEW.md" "### FONT-9 実在しない基準

- 確かめ方: 自動テスト" "$PURPOSE_SPEC"
}
setup_plan_spec_id_without_dir() {
  write_plan "$1/$A/$NEW.md" "$VERIFY_SPEC" "$PURPOSE_SPEC"
}
setup_plan_active_draft() {
  add_font_spec "$1" draft
  write_plan "$1/$A/$NEW.md" "$VERIFY_SPEC" "$PURPOSE_SPEC"
}
setup_plan_active_archived() {
  add_font_spec "$1" archived
  write_plan "$1/$A/$NEW.md" "$VERIFY_SPEC" "$PURPOSE_SPEC"
}
setup_plan_completed_draft() {
  add_font_spec "$1" draft
  write_plan "$1/$C/$NEW.md" "$VERIFY_SPEC" "$PURPOSE_SPEC"
}
setup_plan_no_purpose_path() {
  add_font_spec "$1" approved
  write_plan "$1/$A/$NEW.md" "$VERIFY_SPEC" "$PURPOSE_NONE"
}
setup_plan_purpose_not_in_catalog() {
  add_font_spec "$1" approved
  write_plan "$1/$A/$NEW.md" "$VERIFY_SPEC" "$PURPOSE_SPEC 関連: \`docs/product-specs/list-font-weight.md\`"
}
setup_plan_purpose_other_spec() {
  add_font_spec "$1" approved
  write_spec "$1/$SP/list-font-color.md" "$(criterion COLOR-1)"
  add_catalog_row "$1" COLOR list-font-color.md approved
  write_plan "$1/$A/$NEW.md" "$VERIFY_SPEC" '製品の仕様: `docs/product-specs/list-font-color.md`'
}

# --- 検査 10: レビューの後に足した場合 ---

# 2 つの approved の仕様（FONT と COLOR）を置く
add_two_specs() {
  add_font_spec "$1" approved
  write_spec "$1/$SP/list-font-color.md" "$(criterion COLOR-1)"
  add_catalog_row "$1" COLOR list-font-color.md "$2"
}
VERIFY_TWO="$VERIFY_SPEC

### COLOR-1 文字の色を切り替える

- 確かめ方: 自動テスト"

setup_plan_two_paths_joined() {
  add_two_specs "$1" approved
  write_plan "$1/$A/$NEW.md" "$VERIFY_TWO" '製品の仕様: docs/product-specs/list-font-size.md、docs/product-specs/list-font-color.md'
}
setup_plan_purpose_draft_spec() {
  add_two_specs "$1" draft
  write_plan "$1/$A/$NEW.md" "$VERIFY_SPEC" '製品の仕様: `docs/product-specs/list-font-size.md`、`docs/product-specs/list-font-color.md`'
}
setup_spec_heading_without_title() {
  add_spec_dir "$1"
  write_spec "$1/$SP/list-font-size.md" "$(criterion FONT-1 | sed '1s/^### FONT-1 .*$/### FONT-1/')"
  add_catalog_row "$1" FONT list-font-size.md draft
}
# archived の仕様は、書式（必須の節、基準の項目）を変えた後の形に合わなくても通る。完了した計画はその識別子を引ける
setup_spec_archived_old_format() {
  add_spec_dir "$1"
  write_spec "$1/$SP/list-font-size.md" "$(criterion FONT-1 | grep -v '^- 操作:')"
  grep -vxF '## 利用者の操作の流れ' "$1/$SP/list-font-size.md" > "$1/$SP/tmp" && mv "$1/$SP/tmp" "$1/$SP/list-font-size.md"
  add_catalog_row "$1" FONT list-font-size.md archived
  write_plan "$1/$C/$NEW.md" "$VERIFY_SPEC" "$PURPOSE_SPEC"
}
setup_spec_bad_catalog_header() {
  add_spec_dir "$1"
  sed 's/^| 略号 | 仕様 | 題 | 状態 |$/| 略号 | 題 | 仕様 | 状態 |/' "$1/$SP/README.md" > "$1/$SP/tmp" && mv "$1/$SP/tmp" "$1/$SP/README.md"
}
setup_spec_bad_column_count() {
  add_spec_dir "$1"
  write_spec "$1/$SP/list-font-size.md" "$(criterion FONT-1)"
  printf '| FONT | [list-font-size.md](list-font-size.md) | 文字の大きさ | 切り替え | draft |\n' >> "$1/$SP/README.md"
}
setup_spec_duplicate_catalog_row() {
  add_font_spec "$1" draft
  add_catalog_row "$1" SIZE list-font-size.md draft
}
setup_spec_link_not_direct() {
  add_spec_dir "$1"
  mkdir -p "$1/$SP/sub"
  write_spec "$1/$SP/sub/list-font-size.md" "$(criterion FONT-1)"
  add_catalog_row "$1" FONT sub/list-font-size.md draft
}
setup_spec_archived_open_question() {
  add_spec_dir "$1"
  write_spec "$1/$SP/list-font-size.md" "$(criterion FONT-1)" '- [NEEDS CLARIFICATION: 文字の大きさの段階は 2 つか 3 つか]'
  add_catalog_row "$1" FONT list-font-size.md archived
}
setup_spec_duplicate_item() {
  add_spec_dir "$1"
  write_spec "$1/$SP/list-font-size.md" "$(criterion FONT-1 | awk '{ print } /^- 前提: / { print "- 前提: 二つ目の前提。" }')"
  add_catalog_row "$1" FONT list-font-size.md draft
}

setup_spec_bad_file_name() {
  add_spec_dir "$1"
  write_spec "$1/$SP/List_Font.md" "$(criterion FONT-1)"
  add_catalog_row "$1" FONT List_Font.md draft
}

run_case_if "$SPEC_PRESENT" "仕様: 英小文字・数字・ハイフンでない仕様のファイル名" fail "仕様 $SP/List_Font.md: 仕様のファイル名が英小文字・数字・ハイフンではありません" setup_spec_bad_file_name
run_case_if "$SPEC_PRESENT" "仕様: 目的の節に読点でつないだ 2 つのパス" pass "" setup_plan_two_paths_joined
run_case_if "$SPEC_PRESENT" "仕様: archived の仕様は書式の変更の後も通る" pass "" setup_spec_archived_old_format
run_case_if "$SPEC_PRESENT" "仕様: 目的の節に書いた draft の仕様（識別子は引かない）" fail "進行中の計画 $A/$NEW.md が引く仕様 $SP/list-font-color.md の状態が「draft」です" setup_plan_purpose_draft_spec
run_case_if "$SPEC_PRESENT" "仕様: 題の無い基準の見出し" fail "基準 FONT-1 の見出しに題がありません" setup_spec_heading_without_title
run_case_if "$SPEC_PRESENT" "仕様: 目録の表の見出しの行の列の順序の誤り" fail "目録の表の見出しの行が「略号,題,仕様,状態」です（期待: 略号,仕様,題,状態）" setup_spec_bad_catalog_header
run_case_if "$SPEC_PRESENT" "仕様: 目録の行の列の数の誤り" fail "目録の行（略号 FONT）の列の数が 5 です" setup_spec_bad_column_count
run_case_if "$SPEC_PRESENT" "仕様: 同じ仕様を指す目録の行の重複" fail "目録に、仕様 $SP/list-font-size.md の行が 2 行以上あります" setup_spec_duplicate_catalog_row
run_case_if "$SPEC_PRESENT" "仕様: 目録のリンク先が直下の *.md でない" fail "目録の略号 FONT のリンク先 sub/list-font-size.md が、$SP の直下の仕様のファイルではありません" setup_spec_link_not_direct
run_case_if "$SPEC_PRESENT" "仕様: archived に未決の点が残る" fail "は archived なのに、未決の点" setup_spec_archived_open_question
run_case_if "$SPEC_PRESENT" "仕様: 基準の項目の重複" fail "基準 FONT-1 に「- 前提:」の行が 2 行あります（1 行にする）" setup_spec_duplicate_item

run_case_if "$SPEC_PRESENT" "仕様: 正しい仕様と目録" pass "" setup_spec_correct
run_case_if "$SPEC_PRESENT" "仕様: 目録が空（仕様が 0 件）" pass "" setup_spec_catalog_empty
run_case_if "$NODIR_OK" "仕様: 置き場が無く、V<数字> だけの計画" pass "" setup_spec_no_dir_v_only
run_case_if "$SPEC_PRESENT" "仕様: approved の仕様を引く進行中の計画" pass "" setup_spec_active_approved
run_case_if "$SPEC_PRESENT" "仕様: approved の仕様を引く完了した計画" pass "" setup_spec_completed_approved
run_case_if "$SPEC_PRESENT" "仕様: archived の仕様を引く完了した計画" pass "" setup_spec_completed_archived
run_case_if "$SPEC_PRESENT" "仕様: draft に未決の点が残る" pass "" setup_spec_draft_open_question
run_case "仕様: 旧い書式の計画は仕様と照合しない" pass "" setup_spec_old_plan_ignored

run_case_if "$SPEC_PRESENT" "仕様: 目録に無い仕様のファイル" fail "仕様 $SP/list-font-size.md が目録 $SP/README.md にありません" setup_spec_not_in_catalog
run_case_if "$SPEC_PRESENT" "仕様: 実在しない仕様を指す目録の行" fail "目録の略号 FONT のリンク先 $SP/list-font-size.md がありません" setup_spec_missing_file
run_case_if "$SPEC_PRESENT" "仕様: 状態の値の誤り" fail "状態「done」は、draft・approved・archived のどれでもありません" setup_spec_bad_status
run_case_if "$SPEC_PRESENT" "仕様: 仕様の中の状態の行" fail "に状態の行があります" setup_spec_status_line
run_case_if "$SPEC_PRESENT" "仕様: approved に未決の点が残る" fail "は approved なのに、未決の点" setup_spec_approved_open_question
run_case_if "$SPEC_PRESENT" "仕様: 必須の節の欠け" fail "必須の節の見出し「## 利用者の操作の流れ」の行がありません" setup_spec_missing_section
run_case_if "$SPEC_PRESENT" "仕様: 略号の形の誤り" fail "目録の略号 Font が、英大文字 2〜6 字ではありません" setup_spec_bad_abbr
run_case_if "$SPEC_PRESENT" "仕様: 略号の重複" fail "目録の略号 FONT が重複しています" setup_spec_duplicate_abbr
run_case_if "$SPEC_PRESENT" "仕様: 識別子の重複" fail "受け入れ基準の識別子 FONT-1 が重複しています（重複のある仕様: $SP/list-font-size.md）" setup_spec_duplicate_id
run_case_if "$SPEC_PRESENT" "仕様: 略号と合わない識別子" fail "基準の識別子 SIZE-1 が、この仕様の略号の形（FONT-<数字>）ではありません" setup_spec_id_abbr_mismatch
run_case_if "$SPEC_PRESENT" "仕様: 基準の項目の欠け" fail "基準 FONT-1 に「- 操作:」の行がありません" setup_spec_missing_item
run_case_if "$SPEC_PRESENT" "仕様: 基準が 0 件" fail "受け入れ基準の見出し（「## 受け入れ基準」の下の ### <識別子> <題>）が 1 つもありません" setup_spec_no_criteria
run_case_if "$SPEC_PRESENT" "仕様: コードブロックの中にだけある基準の見出し" fail "受け入れ基準の見出し（「## 受け入れ基準」の下の ### <識別子> <題>）が 1 つもありません" setup_spec_criteria_only_in_code_block
run_case_if "$SPEC_PRESENT" "仕様: 計画が実在しない仕様の識別子を引く" fail "の基準 FONT-9 が、どの製品の仕様の受け入れ基準にもありません" setup_plan_unknown_spec_id
run_case_if "$NODIR_OK" "仕様: 置き場が無いのに V<数字> でない識別子を引く" fail "の基準 FONT-1 は V<数字> ではありませんが、製品の仕様の置き場 $SP がありません" setup_plan_spec_id_without_dir
run_case_if "$SPEC_PRESENT" "仕様: 進行中の計画が draft の仕様を引く" fail "の状態が「draft」です" setup_plan_active_draft
run_case_if "$SPEC_PRESENT" "仕様: 進行中の計画が archived の仕様を引く" fail "の状態が「archived」です" setup_plan_active_archived
run_case_if "$SPEC_PRESENT" "仕様: 完了した計画が draft の仕様を引く" fail "完了した計画 $C/$NEW.md が引く仕様 $SP/list-font-size.md の状態が「draft」です" setup_plan_completed_draft
run_case_if "$SPEC_PRESENT" "仕様: 目的の節に仕様のパスが無い" fail "目的の節に仕様のパスがありません" setup_plan_no_purpose_path
run_case_if "$SPEC_PRESENT" "仕様: 目的の節の仕様のパスが目録に無い" fail "目的の節の仕様 $SP/list-font-weight.md が、目録 $SP/README.md にありません" setup_plan_purpose_not_in_catalog
run_case_if "$SPEC_PRESENT" "仕様: 目的の節の仕様と識別子の所属先が違う" fail "の基準 FONT-1 は仕様 $SP/list-font-size.md の基準ですが、目的の節に書いた仕様にありません" setup_plan_purpose_other_spec

# --- 検査 9: 状態の表で不合格（持ち越しつき）として閉じた基準 ---

# 状態の表を持つ進捗の節の本文。$1 = 基準 V2 の行の根拠
status_progress() {
  printf -- '- %s: 試験の進捗。\n\n### 状態の表\n\n| 項目 | 状態 | 根拠 |\n|---|---|---|\n| V1 (受け入れ確認) | 済 | 合格 |\n| V2 (受け入れ確認) | 不合格 | %s |\n' "$BASE_TODAY" "$1"
}
setup_carry_over() {
  write_plan "$1/$C/$NEW.md" "$VERIFY_NEW" "" "$(status_progress '持ち越し: 次の計画で直す')"
  run_block 1 app-evaluator V1=合格 V2=不合格 > "$1/$C/$NEW.acceptance.md"
}
setup_carry_over_missing() {
  write_plan "$1/$C/$NEW.md" "$VERIFY_NEW" "" "$(status_progress '直せなかった')"
  run_block 1 app-evaluator V1=合格 V2=不合格 > "$1/$C/$NEW.acceptance.md"
}
setup_carry_over_empty() {
  write_plan "$1/$C/$NEW.md" "$VERIFY_NEW" "" "$(status_progress '持ち越し: ')"
  run_block 1 app-evaluator V1=合格 V2=不合格 > "$1/$C/$NEW.acceptance.md"
}
run_case "不合格の基準を、状態の表で持ち越しつきの不合格として閉じた" pass "" setup_carry_over
run_case "状態の表の不合格に持ち越しが無い" fail "根拠に持ち越し先がありません" setup_carry_over_missing
run_case "状態の表の持ち越しが空" fail "根拠に持ち越し先がありません" setup_carry_over_empty

# --- 検査 11: 古い計画 ---

# 基準の日と、そこから数えた日付。日数の計算を試験の側に持たないように、決まった値で書く。
# 写した docs/PLANS.md の「古い計画の日数:」の行を 30 に書き換えた見本で動かす（下の set_stale_days）
T11="2026-12-31"   # 基準の日
D10="2026-12-21"   # 10 日前
D29="2026-12-02"   # 29 日前
D30="2026-12-01"   # 30 日前
D45="2026-11-16"   # 45 日前
D60="2026-11-01"   # 60 日前
NEXT1="2027-01-01"  # 1 日後
NEXT2="2027-01-02"  # 2 日後
LATER="2027-02-01"  # 1 日後より後

set_stale_days() {
  sed 's/^古い計画の日数: [0-9][0-9]*$/古い計画の日数: 30/' "$1/docs/PLANS.md" > "$1/docs/PLANS.md.tmp"
  mv "$1/docs/PLANS.md.tmp" "$1/docs/PLANS.md"
}
write_dated_plan() { # $1 = リポジトリ、$2 = 計画の相対のパス、$3 = 進捗の節の本文、$4 = 目的の節の本文（省略可）
  set_stale_days "$1"
  write_plan "$1/$2" "$VERIFY_V_ONLY" "${4:-$PURPOSE_NONE}" "$3"
}

setup_stale_none() { set_stale_days "$1"; }
setup_stale_name_29_days() { write_dated_plan "$1" "$A/$D29-list-font.md" ""; }
setup_stale_progress_10_days() { write_dated_plan "$1" "$A/$D60-list-font.md" "- $D10: 手順 1 を終えた。"; }
setup_stale_completed() { write_dated_plan "$1" "$C/$D60-list-font.md" ""; }
setup_stale_undated_name_fresh_progress() { write_dated_plan "$1" "$A/list-font.md" "- $D10: 手順 1 を終えた。"; }
setup_stale_next_day_progress() { write_dated_plan "$1" "$A/$D60-list-font.md" "- $NEXT1: 手順 1 を終えた。"; }
setup_stale_29_days_before_leap_day() { write_dated_plan "$1" "$A/2028-01-31-list-font.md" ""; }
setup_stale_29_days_across_year() { write_dated_plan "$1" "$A/2026-12-17-list-font.md" ""; }
setup_stale_both_old() { write_dated_plan "$1" "$A/$D30-list-font.md" "- $D45: 計画を起票した。"; }
setup_stale_no_date() { write_dated_plan "$1" "$A/list-font.md" "- 手順 1 を終えた。"; }
setup_stale_date_only_in_code_block() {
  write_dated_plan "$1" "$A/$D60-list-font.md" "\`\`\`text
- $D10: 手順 1 を終えた。
\`\`\`"
}
setup_stale_date_outside_progress() {
  write_dated_plan "$1" "$A/$D60-list-font.md" "" "一覧の文字の大きさを切り替えられるようにする。製品の仕様は無い。方針は $D10 に決めた。"
}
setup_stale_only_later_date_is_new() { write_dated_plan "$1" "$A/$D60-list-font.md" "- $LATER に再開する。"; }
setup_stale_only_later_dates() { write_dated_plan "$1" "$A/list-font.md" "- $LATER に再開する。"; }
setup_stale_two_days_later_date() { write_dated_plan "$1" "$A/$D60-list-font.md" "- $NEXT2 に再開する。"; }
setup_stale_digits_around_date() { write_dated_plan "$1" "$A/$D60-list-font.md" "- 番号 1$D10 と ${D10}5 を控えた。"; }
setup_stale_april_31() { write_dated_plan "$1" "$A/2027-03-02-list-font.md" "- 2027-04-31: 手順 1 を終えた。"; }
setup_stale_feb_29_common_year() { write_dated_plan "$1" "$A/list-font.md" "- 2027-02-29: 手順 1 を終えた。"; }
setup_stale_30_days_across_leap_february() { write_dated_plan "$1" "$A/2028-01-31-list-font.md" ""; }
setup_stale_no_days_line() {
  grep -v '^古い計画の日数: ' "$1/docs/PLANS.md" > "$1/docs/PLANS.md.tmp"
  mv "$1/docs/PLANS.md.tmp" "$1/docs/PLANS.md"
}

run_case_on "$T11" "古い計画: 進行中の計画が 0 件" pass "" setup_stale_none
run_case_on "$T11" "古い計画: ファイル名の日付が 29 日前" pass "" setup_stale_name_29_days
run_case_on "$T11" "古い計画: ファイル名は 60 日前だが、進捗に 10 日前の日付がある" pass "" setup_stale_progress_10_days
run_case_on "$T11" "古い計画: completed/ の古い計画は対象にしない" pass "" setup_stale_completed
run_case_on "$T11" "古い計画: 名前が日付で始まらないが、進捗に 10 日前の日付がある" pass "" setup_stale_undated_name_fresh_progress
run_case_on "$T11" "古い計画: 進捗に基準の日の 1 日後の日付がある（数える）" pass "" setup_stale_next_day_progress
run_case_on "2027-01-15" "古い計画: 年をまたいで 29 日前" pass "" setup_stale_29_days_across_year
run_case_on "2028-02-29" "古い計画: 基準の日がうるう年の 2 月 29 日（暦にある日付）" pass "" setup_stale_29_days_before_leap_day
run_case_on "$T11" "古い計画: ファイル名が 30 日前で、進捗の日付はそれより前" fail "進行中の計画 $A/$D30-list-font.md が古くなっています（最も新しい日付 $D30 から 30 日" setup_stale_both_old
run_case_on "$T11" "古い計画: 日付を 1 つも読めない計画" fail "進行中の計画 $A/list-font.md の古さを判定できません" setup_stale_no_date
run_case_on "$T11" "古い計画: 進捗の日付がコードブロックの中にだけある" fail "進行中の計画 $A/$D60-list-font.md が古くなっています（最も新しい日付 $D60 から 60 日" setup_stale_date_only_in_code_block
run_case_on "$T11" "古い計画: 進捗の節の外に書いた日付は数えない" fail "進行中の計画 $A/$D60-list-font.md が古くなっています（最も新しい日付 $D60 から 60 日" setup_stale_date_outside_progress
run_case_on "$T11" "古い計画: 進捗の、基準の日の 1 日後より後の日付は数えない" fail "進行中の計画 $A/$D60-list-font.md が古くなっています（最も新しい日付 $D60 から 60 日" setup_stale_only_later_date_is_new
run_case_on "$T11" "古い計画: 数えられる日付が、基準の日の 1 日後より後のものしか無い" fail "進行中の計画 $A/list-font.md の古さを判定できません" setup_stale_only_later_dates
run_case_on "2028-03-01" "古い計画: うるう年の 2 月をまたいで、ちょうど 30 日前" fail "進行中の計画 $A/2028-01-31-list-font.md が古くなっています（最も新しい日付 2028-01-31 から 30 日" setup_stale_30_days_across_leap_february
run_case_on "$T11" "古い計画: 進捗の、基準の日の 2 日後の日付は数えない" fail "進行中の計画 $A/$D60-list-font.md が古くなっています（最も新しい日付 $D60 から 60 日" setup_stale_two_days_later_date
run_case_on "$T11" "古い計画: 前後に数字が続く並びは日付として数えない" fail "進行中の計画 $A/$D60-list-font.md が古くなっています（最も新しい日付 $D60 から 60 日" setup_stale_digits_around_date
run_case_on "2027-05-01" "古い計画: 進捗の 4 月 31 日は数えない" fail "進行中の計画 $A/2027-03-02-list-font.md が古くなっています（最も新しい日付 2027-03-02 から 60 日" setup_stale_april_31
run_case_on "2027-03-01" "古い計画: 進捗の日付が平年の 2 月 29 日だけ" fail "進行中の計画 $A/list-font.md の古さを判定できません" setup_stale_feb_29_common_year
run_case_on "2026-13-01" "古い計画: 基準の日が日付の形でない" fail "環境変数 HARNESS_TODAY の値「2026-13-01」が、YYYY-MM-DD の形の、暦にある日付ではありません" setup_stale_none
run_case_on "$T11" "古い計画: docs/PLANS.md に日数の行が無い" fail "「古い計画の日数: <整数>」の行がありません" setup_stale_no_days_line

# --- 設定のファイル ---

conf_add() { printf '%s\n' "$2" >> "$1/scripts/harness/harness.conf"; }
setup_conf_hash_in_regex() {
  conf_add "$1" "# 行頭の # は注釈"
  conf_add "$1" 'record_exempt_line_re=^(?<name>[a-z]+)#(?<ver>[0-9]+)$'
}
setup_conf_unknown_key() { conf_add "$1" "no_such_key=1"; }
setup_conf_duplicate_key() { conf_add "$1" "format=1"; }
setup_conf_trailing_comment() {
  grep -v '^agents_max_lines=' "$1/scripts/harness/harness.conf" > "$1/conf.tmp"
  mv "$1/conf.tmp" "$1/scripts/harness/harness.conf"
  conf_add "$1" "agents_max_lines=120 # 上限"
}
setup_conf_regex_without_name() { conf_add "$1" 'record_exempt_line_re=^[a-z]+$'; }
setup_conf_regex_without_ver() { conf_add "$1" 'record_exempt_line_re=^(?<name>[a-z]+)#[0-9]+$'; }
setup_conf_missing() { rm -f "$1/scripts/harness/harness.conf"; }
conf_set() { # <根> <キー> <値>: 1 回だけ書けるキーを置き換える
  grep -v "^$2=" "$1/scripts/harness/harness.conf" > "$1/conf.tmp"
  mv "$1/conf.tmp" "$1/scripts/harness/harness.conf"
  conf_add "$1" "$2=$3"
}
setup_conf_bad_exts() { conf_set "$1" arch_root_file_exts "md,json"; }
setup_conf_parts_ok() { conf_add "$1" "part=sample-a"; conf_add "$1" "part=sample-b"; }
setup_conf_bad_part() { conf_add "$1" "part=../x"; }
setup_conf_dash_branch() { conf_set "$1" default_branch "-main"; }
run_case "設定: # を含む正規表現の値と、行頭の # の注釈" pass "" setup_conf_hash_in_regex
run_case "設定: 知らないキー" fail "知らないキー no_such_key があります" setup_conf_unknown_key
run_case "設定: 1 回だけ書けるキーの重複" fail "キー format が 2 回以上あります" setup_conf_duplicate_key
run_case "設定: 値の後ろの注釈は値の一部になる" fail "agents_max_lines の値「120 # 上限」が 1 以上の整数ではありません" setup_conf_trailing_comment
run_case "設定: 名前つきの捕獲の無い正規表現" fail "名前つきの捕獲 (?<name>…) と (?<ver>…) を持つ perl の正規表現ではありません" setup_conf_regex_without_name
run_case "設定: 設定のファイルが無い" fail "設定のファイル scripts/harness/harness.conf がありません" setup_conf_missing
run_case "設定: 版の部分の捕獲 ver の無い正規表現" fail "と (?<ver>…) を持つ perl の正規表現ではありません" setup_conf_regex_without_ver
run_case "設定: 拡張子の並びの形の誤り" fail "arch_root_file_exts の値「md,json」が" setup_conf_bad_exts
run_case "設定: 採用した部品の行（part）は何行でも書ける" pass "" setup_conf_parts_ok
run_case "設定: 部品の名前の形の誤り" fail "part の値「../x」が部品の名前" setup_conf_bad_part
run_case "設定: - で始まる既定のブランチ" fail "default_branch の値「-main」に使えない文字があります" setup_conf_dash_branch

# --- 検査 12: 検査の由来の記録 ---

tgit() {
  git -c user.name=test -c user.email=test -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    -c core.fsmonitor=false "$@"
}
SHA_A="1111111111111111111111111111111111111111"
SHA_B="2222222222222222222222222222222222222222"
# 地図に検査と記録の行を足し、記録と検査を定めるファイルを置いてコミットし、origin/main をそのコミットにする
base_with_log() {
  printf '%s\n' '| 検査 | `scripts/harness/` |' '| 検査の由来の記録 | `docs/harness-log.md` |' >> "$1/AGENTS.md"
  printf '%s\n' "# 検査の由来の記録" "" "| 検査 | 元の指摘の出どころ | 備考 |" "|---|---|---|" > "$1/docs/harness-log.md"
  printf '%s\n' "steps:" "  - uses: actions/checkout@$SHA_A # v1" > "$1/scripts/harness/ci-step.yml"
  conf_add "$1" 'record_exempt_line_re=^\s*-?\s*uses:[ \t]*(?<name>[^@\s]+)@(?<ver>[0-9a-f]{40}(\s+#.*)?)$'
  tgit -C "$1" add -A
  tgit -C "$1" commit -q -m "見本"
  tgit -C "$1" update-ref refs/remotes/origin/main HEAD
}
setup_log_missing_row() { base_with_log "$1"; printf 'echo x\n' > "$1/scripts/harness/new-check.sh"; }
setup_log_with_row() {
  base_with_log "$1"
  printf 'echo x\n' > "$1/scripts/harness/new-check.sh"
  printf '| 新しい検査 | 試験 | なし |\n' >> "$1/docs/harness-log.md"
}
setup_log_version_only() {
  base_with_log "$1"
  printf '%s\n' "steps:" "  - uses: actions/checkout@$SHA_B # v2" > "$1/scripts/harness/ci-step.yml"
}
setup_log_other_action() {
  base_with_log "$1"
  printf '%s\n' "steps:" "  - uses: actions/other@$SHA_B # v2" > "$1/scripts/harness/ci-step.yml"
}
setup_log_add_uses() {
  base_with_log "$1"
  printf '%s\n' "steps:" "  - uses: actions/checkout@$SHA_A # v1" "  - uses: actions/other@$SHA_B # v2" > "$1/scripts/harness/ci-step.yml"
}
setup_log_remove_uses() {
  base_with_log "$1"
  printf '%s\n' "steps:" > "$1/scripts/harness/ci-step.yml"
}
setup_log_reindent() {
  base_with_log "$1"
  printf '%s\n' "steps:" "    - uses: actions/checkout@$SHA_A # v1" > "$1/scripts/harness/ci-step.yml"
}
setup_log_version_and_dash() {
  base_with_log "$1"
  printf '%s\n' "steps:" "  uses: actions/checkout@$SHA_B # v2" > "$1/scripts/harness/ci-step.yml"
}
setup_log_not_scoped() { base_with_log "$1"; printf 'x\n' > "$1/docs/other.txt"; }
setup_log_github_base_missing() { base_with_log "$1"; CASE_ENV=(GITHUB_BASE_REF=no-such-branch); }
setup_log_github_base_ok() { setup_log_with_row "$1"; CASE_ENV=(GITHUB_BASE_REF=main); }
run_case "由来の記録: 検査を変えて記録に行を足した" pass "" setup_log_with_row
run_case "由来の記録: 検査を変えたのに記録に行が無い" fail "検査の由来の記録 docs/harness-log.md に行が足されていません" setup_log_missing_row
run_case "由来の記録: アクションの版だけの置き換えは記録を求めない" pass "" setup_log_version_only
run_case "由来の記録: 名前の違う置き換えは記録を求める" fail "検査の由来の記録 docs/harness-log.md に行が足されていません" setup_log_other_action
run_case "由来の記録: uses: の行を 1 行足すのは記録を求める" fail "検査の由来の記録 docs/harness-log.md に行が足されていません" setup_log_add_uses
run_case "由来の記録: uses: の行を 1 行消すのは記録を求める" fail "検査の由来の記録 docs/harness-log.md に行が足されていません" setup_log_remove_uses
run_case "由来の記録: 版を変えずに字下げだけを変えるのは記録を求める" fail "検査の由来の記録 docs/harness-log.md に行が足されていません" setup_log_reindent
run_case "由来の記録: 版と一緒に先頭の - を変えるのは記録を求める" fail "検査の由来の記録 docs/harness-log.md に行が足されていません" setup_log_version_and_dash
run_case "由来の記録: 検査でないファイルの変更は記録を求めない" pass "" setup_log_not_scoped
run_case "由来の記録: GITHUB_BASE_REF の分岐元を読めない" fail "検査の由来の記録を調べる分岐元を読めません" setup_log_github_base_missing
run_case "由来の記録: GITHUB_BASE_REF の分岐元で調べる" pass "" setup_log_github_base_ok

# --- 検査 13: 写しの中身 ---

sha_of() { perl -MDigest::SHA=sha256_hex -e 'local $/; open(my $f, "<:raw", $ARGV[0]) or die; print sha256_hex(<$f>)' "$1"; }
# 正本の見本を作り、写しとして置く。$1 = リポジトリ、$2 = 写しの本文を変えるか（yes / no）
put_copy() {
  local d="$1" body="$TMP_ROOT/copy-body.sh"
  printf '#!/usr/bin/env bash\necho copy\n' > "$body"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# harness-copy: source=home/agents/skills/project-harness-init/assets/harness/x.sh\n'
    printf '# harness-copy: version=rules-2099.01.01-1\n'
    printf '# harness-copy: sha256=%s\n' "$(sha_of "$body")"
    printf '# harness-copy: この 4 行と本体は手で変えない\n'
    if [ "$2" = yes ]; then printf 'echo edited\n'; else printf 'echo copy\n'; fi
  } > "$d/scripts/harness/x-copy.sh"
}
setup_copy_ok() { put_copy "$1" no; }
setup_copy_edited() { put_copy "$1" yes; }
setup_region_edited() {
  awk '{ print } /^<!-- harness-copy: region=plan-status-spec / { print "手で足した行。" }' "$1/docs/PLANS.md" > "$1/docs/PLANS.md.tmp"
  mv "$1/docs/PLANS.md.tmp" "$1/docs/PLANS.md"
}
REGION_PRESENT=0
grep -q '^<!-- harness-copy: region=plan-status-spec ' "$PLANS" && REGION_PRESENT=1
run_case "写し: 冒頭の行の sha256 と中身が合う" pass "" setup_copy_ok
run_case "写し: 中身を手で変えた" fail "写し scripts/harness/x-copy.sh の中身が合いません" setup_copy_edited
run_case_if "$REGION_PRESENT" "写し: docs/PLANS.md の区画を手で変えた" fail "写し docs/PLANS.md の区画 plan-status-spec の中身が合いません" setup_region_edited

# --- 追加の検査の口（checks.d/） ---

put_extra() { # $1 = リポジトリ、$2 = ファイル名、$3 = 本文（# 検査の名前 の行の後ろ）、$4 = 名前の行（省略時は「例」）
  mkdir -p "$1/scripts/harness/checks.d"
  printf '#!/usr/bin/env bash\n%s\n%s\n' "${4-# 検査の名前: 例}" "$3" > "$1/scripts/harness/checks.d/$2"
}
setup_extra_pass() { put_extra "$1" a.sh '[ "$HARNESS_ROOT" = "$(pwd)" ] && [ -f "$HARNESS_ENGINE_DIR/check-docs.sh" ] || exit 1'; }
setup_extra_fail() { put_extra "$1" a.sh 'echo "check-docs: NG: 例の不合格"; echo "check-docs: NG: 例の二つ目"; exit 1'; }
setup_extra_error() { put_extra "$1" a.sh 'exit 3'; }
setup_extra_no_name() { put_extra "$1" a.sh 'exit 0' "# 名前の行が無い"; }
setup_extra_test_not_run() { put_extra "$1" a.sh 'exit 0'; put_extra "$1" a.test.sh 'exit 1'; }
setup_extra_symlink() { put_extra "$1" real.txt 'exit 0'; ln -s real.txt "$1/scripts/harness/checks.d/b.sh"; }
run_case "追加の検査: 合格（作業ディレクトリと環境変数を受け取る）" pass "" setup_extra_pass
run_case "追加の検査: 不合格の行を件数に足す" fail "check-docs: 2 件の問題があります" setup_extra_fail
run_case "追加の検査: 0 と 1 以外の終了コード" fail "追加の検査 例（scripts/harness/checks.d/a.sh）を実行できませんでした（終了コード 3）" setup_extra_error
run_case "追加の検査: 名前の行が無い" fail "に「# 検査の名前: <短い名前>」の行がちょうど 1 行ありません" setup_extra_no_name
run_case "追加の検査: 名前が .test.sh で終わるものは実行しない" pass "" setup_extra_test_not_run
run_case "追加の検査: シンボリックリンクは失敗にする" fail "追加の検査 scripts/harness/checks.d/b.sh がシンボリックリンクか" setup_extra_symlink

# --print の出力（検査はしない）
d="$TMP_ROOT/print"
make_base "$d"
put_extra "$d" a.sh 'exit 0'
names="$(bash "$d/scripts/harness/check-docs.sh" --print checks 2>&1 || true)"
if [ "$(printf '%s\n' "$names" | wc -l | tr -d ' ')" -eq 14 ] && [ "$(printf '%s\n' "$names" | tail -n 1)" = "例" ] \
  && [ "$(printf '%s\n' "$names" | head -n 1)" = "必須のファイル" ]; then
  echo "ok: --print checks（13 個の名前と、追加の検査の名前）"
  passed=$((passed + 1))
else
  echo "NG: --print checks の出力が違います" >&2
  printf '%s\n' "$names" | sed 's/^/    /' >&2
  failed=$((failed + 1))
fi
# 冒頭の注釈の検査の一覧（「#   1. …」の形の行）の番号が 1 から欠けずに並び、その数が検査の数（追加の検査の無い見本の
# --print checks の行の数）と同じか。番号を集めるのは、冒頭の注釈のうち最初の注釈でない行（set -euo pipefail の手前）
# まで（本文の見出しの「# 1.」などは数えない）。$1 = 確かめる check-docs.sh、$2 = 見本を作る置き場。合えば 0
header_numbers_match() {
  local nums count
  make_base "$2"
  cp "$1" "$2/scripts/harness/check-docs.sh"
  nums="$(awk '!/^#/ { exit } /^# +[0-9]+\./ { sub(/^# +/, ""); sub(/\..*$/, ""); print }' "$1")"
  count="$(bash "$2/scripts/harness/check-docs.sh" --print checks 2> /dev/null | wc -l | tr -d ' ')"
  [ -n "$nums" ] && [ "$count" -gt 0 ] || return 1
  printf '%s\n' "$nums" | awk -v n="$count" '$0 != NR { bad = 1 } END { exit (bad || NR != n) ? 1 : 0 }'
}
if header_numbers_match "$CHECK" "$TMP_ROOT/header-numbers"; then
  echo "ok: 冒頭の注釈の検査の一覧の番号が 1 から欠けずに並び、数が --print checks と同じ"
  passed=$((passed + 1))
else
  echo "NG: check-docs.sh の冒頭の注釈の検査の一覧の番号が、1 から欠けずに並んでいないか、数が --print checks の行の数と違います" >&2
  failed=$((failed + 1))
fi
# 照合が働くことの確かめ: 冒頭の一覧から 5 番の行を抜いた写しでは合わない
awk '!/^#/ { body = 1 } body || !/^# +5\./' "$CHECK" > "$TMP_ROOT/check-docs-gap.sh"
if ! header_numbers_match "$TMP_ROOT/check-docs-gap.sh" "$TMP_ROOT/header-numbers-gap"; then
  echo "ok: 冒頭の注釈の検査の一覧の番号が 1 つ欠けた写しでは、照合が合わない"
  passed=$((passed + 1))
else
  echo "NG: 冒頭の注釈の検査の一覧の番号が 1 つ欠けた写しでも、照合が合ってしまいます" >&2
  failed=$((failed + 1))
fi
re="$(bash "$d/scripts/harness/check-docs.sh" --print arch-path-re 2>&1 || true)"
if printf '%s\n' "templates/module/README.md" | grep -Eq -- "$re" && ! printf '%s\n' "lib/x" | grep -Eq -- "$re"; then
  echo "ok: --print arch-path-re（設定の接頭辞から作る）"
  passed=$((passed + 1))
else
  echo "NG: --print arch-path-re の出力が違います: $re" >&2
  failed=$((failed + 1))
fi
conf_set "$d" arch_root_file_exts "md"
re="$(bash "$d/scripts/harness/check-docs.sh" --print arch-path-re 2>&1 || true)"
if printf '%s\n' "README.md" | grep -Eq -- "$re" && ! printf '%s\n' "config.json" | grep -Eq -- "$re"; then
  echo "ok: --print arch-path-re（根の直下の拡張子は arch_root_file_exts から作る）"
  passed=$((passed + 1))
else
  echo "NG: arch_root_file_exts が --print arch-path-re に効いていません: $re" >&2
  failed=$((failed + 1))
fi
conf_add "$d" "part=sample-a"
v_branch="$(bash "$d/scripts/harness/check-docs.sh" --print conf default_branch 2>&1 || true)"
v_part="$(bash "$d/scripts/harness/check-docs.sh" --print conf part 2>&1 || true)"
rc_unknown=0
bash "$d/scripts/harness/check-docs.sh" --print conf no_such_key > /dev/null 2>&1 || rc_unknown=$?
if [ -n "$v_branch" ] && printf "%s\n" "$v_part" | grep -qx sample-a && [ "$rc_unknown" -eq 2 ]; then
  echo "ok: --print conf（1 回だけのキー、何行でも書けるキー、知らないキーは終了コード 2）"
  passed=$((passed + 1))
else
  echo "NG: --print conf の出力が違います（default_branch: ${v_branch}、part: ${v_part}、知らないキーの終了コード: ${rc_unknown}）" >&2
  failed=$((failed + 1))
fi

# --- プロジェクト専用の検査の試験（このファイルの置き場の checks.d/*.test.sh） ---
for t in "$SELF/checks.d/"*.test.sh; do
  [ -e "$t" ] || continue
  if env -u GITHUB_BASE_REF -u HARNESS_BASE_REF bash "$t"; then
    echo "ok: 追加の検査の試験 $(basename "$t")"
    passed=$((passed + 1))
  else
    echo "NG: 追加の検査の試験 $(basename "$t") が失敗しました" >&2
    failed=$((failed + 1))
  fi
done

total=$((passed + failed))
if [ "$failed" -gt 0 ]; then
  echo "check-docs.test: $total 件中 $failed 件が期待と違います（直した後に $TEST_COMMAND で確かめ直す）" >&2
  exit 1
fi
echo "check-docs.test: $total 件中 $total 件が期待どおり（このプロジェクトに当てはまらない $skipped 件は動かしていない）"
