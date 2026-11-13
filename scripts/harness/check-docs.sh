#!/usr/bin/env bash
# harness-copy: source=home/agents/skills/project-harness-init/assets/harness/check-docs.sh
# harness-copy: version=rules-2026.11.13-1
# harness-copy: sha256=ce604b3a53321792aded7879d6f09393353b447708f7b81be4fee3830b3e1b3f
# harness-copy: この 4 行と本体は手で変えない。正本を直して project-harness-init の「導入済みのプロジェクトの更新」で置き換える
# 文書の検査（ハーネスの検査の本体）。どのプロジェクトでも同じ中身の写しを scripts/harness/check-docs.sh に置く。
# プロジェクトごとの値は、同じ置き場の設定のファイル harness.conf と、プロジェクトの文書から読む。プロジェクト専用の
# 検査は、同じ置き場の checks.d/ に置く（このファイルを直さない）。
#
# 使い方:
#   check-docs.sh                        自分の置き場（scripts/harness/）から根を決めて検査する
#   check-docs.sh --root <絶対パス>       その git の作業ツリーの根を検査する（早期通知が、別の作業ツリーを検査する形）
#   check-docs.sh --print arch-path-re    検査 7 が拾うパスの正規表現を 1 行で出す（定期の走査が使う）。検査はしない
#   check-docs.sh --print checks          検査の短い名前を 1 行に 1 つ出す（下の 14 個と、追加の検査の口の名前）。検査はしない
#   check-docs.sh --print conf <キー>     設定のキーの値を出す（1 回だけのキーは既定を補い、何行でも書けるキーは 1 行に 1 つ）
# 設定、追加の検査（checks.d/）、必須のファイルの一覧は、どの呼び方でも起動元（このファイルの置き場）のものを使う。
# 検査する作業ツリーは文書としてだけ読み、そこのファイルを実行も読み込みもしない（別のブランチが書き換えたスクリプトを、
# 利用者の権限で動かさないため）。git の呼び出しには -c core.fsmonitor=false を付ける。
#
# 設定のファイル（scripts/harness/harness.conf）: 1 行に 1 つの「キー=値」。行頭が # の行と空の行は注釈として読み飛ばす。
# 値の後ろに注釈を書けない（# も値の一部になる）。source しない。知らないキーと、1 回だけ書けるキーの重複は「設定の誤り」。
#   format=1                       設定の書式の版（1 だけ）
#   agents_max_lines=<整数>        AGENTS.md の行数の上限（検査 6。既定 120）
#   required.<版>=<パス>           ハーネスの版ごとの必須のファイル（検査 1。1 行に 1 つ、何行でも。末尾が / はディレクトリ）
#   claude_md_exact=yes|no         yes: CLAUDE.md が「@AGENTS.md」の 1 行と完全に一致する。no: その行があればよい（既定 no）
#   arch_path_prefixes=<名前>...   検査 7 が拾うパスの先頭のディレクトリ（空白で区切る。既定 src docs scripts .github templates）
#   arch_root_file_exts=<拡張子>... 検査 7 が拾う、根の直下のファイルの拡張子（空白で区切る。既定 md cjs mjs ts json yml）
#   default_branch=<名前>          既定のブランチ（検査 12 の分岐元と、定期の走査が使う。既定 main）
#   template_version=<版>          敷いたひな形の版（更新の手順が使う。検査はしない）
#   part=<名前>                    敷いたときに採用した部品の名前（何行でも。更新の手順が使う。検査はしない）
#   record_exempt_line_re=<正規表現>  検査 12 で記録を求めない行の置き換えの形（何行でも。perl の正規表現で、名前つきの捕獲
#                                  (?<name>…) と版の部分の捕獲 (?<ver>…) を持つ）
#
# 確かめること:
#   1. AGENTS.md に導入済みの印（「ハーネスの版: N」の 1 行）があり、その版で必須のファイル（設定の required.<版>）が実在する
#   2. CLAUDE.md があるとき、「@AGENTS.md」だけの行がある（設定の claude_md_exact=yes なら、その 1 行と完全に一致する）
#   3. AGENTS.md の「文書の地図」に書いたパスが実在する
#   4. Markdown の相対リンクの先が実在する。対応する構文は、インラインのリンクと画像（[文字](先)、![文字](先)）で、
#      先に空白も「)」も含まないものだけ。参照形式（[文字][名前] と [名前]: 先）、山括弧で囲んだ先、タイトル付きの先、
#      自動リンク（<https://...>）、HTML の a 要素は対象外で、リンク先が無くても検出しない。
#      一覧にあるのに検査できない Markdown（シンボリックリンク、読めないもの）は失敗にする
#   5. docs/adr/ の ADR が、すべて目録（docs/adr/README.md）に載っている
#   6. AGENTS.md の行数が上限以下
#   7. ARCHITECTURE.md に書いたパスが実在する（拾う形は --print arch-path-re の正規表現）
#   8. 進行中と完了の計画（docs/exec-plans/active/ と completed/ の直下の .md のうち、名前が .acceptance.md で
#      終わらないもの）に、docs/PLANS.md の「必須の節」の一覧にある見出しが、すべて行として揃っている。
#      ``` で囲んだコードブロックの中の行は見出しに数えない。
#      CR（\r）を含む計画は、改行を直すよう求める 1 件の失敗にし、見出しは照合しない。
#      計画が 0 件のときも、docs/PLANS.md から見出しを読み取れることは確かめる
#   9. 受け入れ確認の記録（docs/PLANS.md の「受け入れ確認の記録」）。
#      - すべての記録（active/ と completed/ の直下の *.acceptance.md）: 同じディレクトリに同じ名前の計画がある。
#        絶対パスの形（/Users/、/home/、/private/、/tmp/、/var/folders/）を含まない
#      - completed/ の計画のうち、ファイル名の日付が docs/PLANS.md の「新しい書式の適用開始: YYYY-MM-DD」以降のもの
#        （日付で始まらない名前の計画も含める）: 検証の節の「### <識別子>」の見出しの下で、確かめ方が受け入れ確認の
#        基準ごとに、記録の中の「確かめた者: app-evaluator」の実行のうち、その基準の行を持つ最も後の実行の結果が「合格」。
#        ただし、計画の「## 進捗」の「### 状態の表」で、その基準の行（項目が <識別子> か「<識別子> (」で始まる行）の
#        状態が「不合格」で、根拠に空でない「持ち越し: <先>」があれば失敗にしない（持ち越しが無いか空なら失敗にする）。
#        あわせて、検証の節の書式（check_plan_verification）と、記録の書式（check_record_format）を確かめる。
#      - 計画と記録のどちらも、``` で囲んだコードブロックの中の行は数えない
#  10. 製品の仕様（書式と目録の正本は docs/product-specs/README.md）。
#      (1)〜(5) は docs/product-specs/ があるときだけ働く（利用者に見える機能を持つプロジェクトに置く、条件付きの種類のため）:
#      (1) 目録（README.md の「## 目録」の表）から、略号・仕様のリンク先・状態を読む。表の見出しの行が「略号・仕様・題・状態」の
#          4 列で、各行も 4 列。行が 0 行でもよい
#      (2) 直下の *.md（README.md を除く）がすべて目録に 1 行ずつある／目録のリンク先が直下の *.md で実在する／同じ仕様を指す行が
#          重ならない／略号が英大文字 2〜6 字で重複しない
#      (3) 状態が draft・approved・archived のどれか／仕様のファイルに状態の行（「状態:」で始まる行）が無い／
#          approved と archived の仕様に [NEEDS CLARIFICATION: が残っていない
#      (4) 各仕様に、README.md の「必須の節」の一覧の見出しがすべて行としてある（検査 8 と同じ関数）
#      (5) 「## 受け入れ基準」の「### <識別子> <題>」の識別子が「<略号>-<数字>」で、題があり、同じ仕様の中でも仕様をまたいでも
#          重複しない。各見出しの下に「- 前提:」「- 操作:」「- 期待する結果:」が 1 行ずつある。基準が 1 つ以上ある
#      archived の仕様は、(4) と (5) の書式（必須の節、題、識別子の形、項目の行、基準の数）を調べず、識別子だけを集める
#      （書式を後から変えても、過去の仕様を失敗にしないため）
#      (6)(7) は、仕様の置き場が無くても、新しい書式の計画（active/ と completed/）に対して常に働く:
#      (6) 検証の節の識別子のうち V<数字> でないものが、どれかの仕様の受け入れ基準として実在する。目的の節に書いた仕様と、
#          識別子の所属先の仕様の状態は、active/ の計画では approved、completed/ の計画では approved か archived
#      (7) 目的の節に書いた仕様のパス（docs/product-specs/<名前>.md。名前は英小文字・数字・ハイフン）が目録にあり、検証の節の仕様の識別子の所属先が、
#          目的の節に書いた仕様のどれかと一致する
#      仕様と計画のどちらも、``` で囲んだコードブロックの中の行は数えない
#  11. 古い計画（決まりの正本は docs/PLANS.md の「置き場所と名前」）。進行中の計画（docs/exec-plans/active/ の直下の .md のうち、
#      名前が .acceptance.md で終わらないもの）について、ファイル名の先頭の日付と、「## 進捗」の節の中の YYYY-MM-DD の形の
#      日付のうち、最も新しい日付が、基準の日より、docs/PLANS.md の「古い計画の日数: <整数>」の行の日数以上前なら失敗にする。
#      基準の日の 1 日後より後の日付は数えない（予定の日付を、進めた日付と読み違えないため。手元と CI の時刻帯の差が
#      あるので、1 日後までは数える）。暦に無い日付と、前後に数字が続く並び（12026-10-07 など）も数えない。
#      数える日付が 1 つも無い計画も失敗にする。``` で囲んだコードブロックの中の行は数えない。completed/ の計画と、
#      受け入れ確認の記録は対象にしない。docs/PLANS.md に日数の行が無ければ失敗にする。
#      基準の日は、環境変数 HARNESS_TODAY（YYYY-MM-DD。試験用）があればその日、無ければ実行した日。
#      HARNESS_TODAY が暦にある日付でなければ失敗にする
#  12. 検査の由来の記録。地図の「検査の由来の記録」の行が示す記録に、検査を定めるファイル（地図の 1 列目が「検査」か
#      「検査（」で始まる行の、2 列目のバッククォートの中のパス。末尾が / なら、その下のすべて）を変えた変更が、記録の表の
#      行を 1 行以上足している。比べる元は分岐元（環境変数 GITHUB_BASE_REF があれば origin/<その値> との merge-base で、
#      求められなければ失敗にする。無ければ HARNESS_BASE_REF、origin/<既定のブランチ>、<既定のブランチ> の順の最初に
#      あるものとの merge-base で、どれも無ければ調べない）。変えたファイルは、分岐元からの差分（作業ツリーを含む）と、
#      除外されていない未追跡のファイル。調べないとき: 地図に「検査の由来の記録」の行が無い、分岐元の時点の AGENTS.md に
#      導入済みの印が無い、分岐元の時点に記録のファイルが無い（導入の変更そのもの）。当たったファイルの差分が、どの塊でも、
#      消した行と足した行が同じ数で、対になる行同士が設定の record_exempt_line_re の同じ規則に合い、名前の部分（name）が
#      同じで、版の部分（ver）が違い、行から版の部分を除いた残りが同じ（版だけを置き換えた）ときは、記録を求めない
#  13. 写しの中身。追跡しているファイルと除外されていない未追跡のファイルのうち、冒頭に harness-copy の行があるもの（写し）と、
#      .md の区画の写し（begin の印の次の行が harness-copy の行の区画）について、冒頭の行の sha256 が、
#      冒頭の行を除いた中身の sha256 と一致する（うっかりした編集を拾う。正本と同じであることの証明にはならない。
#      正本と比べるのは project-harness-init の harness-copies.sh）
#  14. 製品の機能の一覧（書式の正本は、製品の前提の区画 roadmap-spec。製品の前提は、地図の「製品の前提」の行のパス）。
#      (a) 区画の後の「### 一覧」の表の形（見出しの行が「識別子・機能・状態・達成の条件・根拠」の 5 列、各行も 5 列）、識別子
#          （F-<数字>）の重複、状態の値（残り・済・取りやめ）、達成の条件の形（基準: <並び>; 環境: <環境>[; 確かめること: <文>]）。
#          区画の無い文書（旧い形）と、区画の後に「### 一覧」の無い文書は、行が 0 の一覧として扱う。状態によらず、達成の条件に
#          明示した基準の識別子（- と <略号>-* を除く）が、製品の仕様の受け入れ基準にある
#      (b) 済の行: 達成の条件の基準が製品の仕様の受け入れ基準にあり（<略号>-* は、その略号の基準のすべて）、根拠に実在する
#          完了した計画（docs/exec-plans/completed/<名前>.md）があり、その状態の表で、基準の行（子項目を宣言した基準は、宣言した
#          子の行のすべて）がすべてあって済（状態の欄が空の行も済ではない）。検証の節で確かめ方が人が確認の基準は、状態の表の根拠に日付（YYYY-MM-DD）がある
#      (c) 進行中と完了した計画と、archived でない仕様の「持ち越し: F-<数字>」が、表にある（表が無ければ失敗）
#      (d) 進行中の計画の「持ち越し: TD-<数字>」が、技術的負債の一覧（地図の行。無ければ docs/exec-plans/tech-debt-tracker.md）の
#          表の行にある（完了した計画は調べない）
#      (e) 分岐元（検査 12 と同じ求め方。GITHUB_BASE_REF があるのに求められなければ、機能の一覧を導入したプロジェクト〔今の
#          地図に製品の前提の行があるか、計画か仕様に「持ち越し: F-<数字>」がある〕でだけ失敗、手元で求められなければ調べない）の
#          地図に製品の前提の行があり、その文書に区画があるとき（比べるかは分岐元で決め、今の地図は問わない）: 今の地図に製品の
#          前提の行が無いか、今の製品の前提（今の地図のパス）に区画が無い／分岐元の F-<数字> の行が無い／分岐元の行の機能の名前か
#          達成の条件を変えたか、取りやめにしたのに、分岐元の根拠に無い「利用者の決定: <場所>」が根拠に足されていない（根拠の
#          項目は「; 」か「；」で区切り、場所はその項目の終わりまで）。
#          分岐元に区画の無い文書（旧い形）は調べない
#      計画・仕様・製品の前提のどれも、``` で囲んだコードブロックの中の行は数えない
# この 14 個の後に、追加の検査の口（起動元の scripts/harness/checks.d/ の *.sh のうち、名前が .test.sh で終わらないもの）を、
# 名前の順に 1 つずつ実行する。決まりは checks.d/README.md（ファイルの 2 行目以降に「# 検査の名前: <短い名前>」をちょうど
# 1 行。bash で呼び、作業ディレクトリは検査する根、標準入力は /dev/null。環境変数 HARNESS_ROOT と HARNESS_ENGINE_DIR を渡す。
# 終了コード 0 は合格、1 は不合格で、出力の「check-docs: NG:」の行の数を件数に足す。ほかの終了コードは、実行できなかった
# 1 件の失敗にする）。シンボリックリンクと、名前の行の無いものは失敗にする。
#
# 失敗したときは、項目ごとに直し方を表示して、終了コード 1 で終わる。引数の誤りは終了コード 2。
set -euo pipefail
export LC_ALL=C
# 繰り返し使う制御文字（コマンド置換で作ると、使うたびにプロセスを起動するため）
CR=$'\r'
TAB=$'\t'
NL=$'\n'

usage_error() {
  echo "check-docs: NG: $1" >&2
  echo "  使い方: check-docs.sh [--root <git の作業ツリーの根の絶対パス> | --print arch-path-re | --print checks | --print conf <キー>]" >&2
  exit 2
}

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CONF="$SELF_DIR/harness.conf"
PRINT=""
PRINT_KEY=""
if [ "$#" -eq 0 ]; then
  ROOT="$(cd "$SELF_DIR/../.." && pwd)"
elif [ "$#" -eq 2 ] && [ "$1" = "--print" ]; then
  case "$2" in
    arch-path-re|checks) PRINT="$2" ;;
    *) usage_error "--print の値が違います（arch-path-re か checks）" ;;
  esac
  ROOT=""
elif [ "$#" -eq 3 ] && [ "$1" = "--print" ] && [ "$2" = conf ]; then
  PRINT=conf; PRINT_KEY="$3"; ROOT=""
elif [ "$#" -eq 2 ] && [ "$1" = "--root" ]; then
  ROOT="$2"
  case "$ROOT" in
    /*) ;;
    *) usage_error "--root の値が絶対パスではありません" ;;
  esac
  [ -d "$ROOT" ] || usage_error "--root の値がディレクトリではありません"
  root_top="$(git -c core.fsmonitor=false -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" \
    || usage_error "--root の値が git の作業ツリーの中ではありません"
  if [ -z "$root_top" ] || [ "$(cd -- "$ROOT" && pwd -P)" != "$(cd -- "$root_top" && pwd -P)" ]; then
    usage_error "--root の値が git の作業ツリーの根ではありません"
  fi
else
  usage_error "引数の形が違います"
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

g() {
  git -c core.fsmonitor=false -c core.quotePath=false "$@"
}

# --- 設定のファイル ---
CONF_SINGLE_KEYS="format agents_max_lines claude_md_exact arch_path_prefixes arch_root_file_exts default_branch template_version"
CONF_MULTI_KEYS="record_exempt_line_re part"
conf_tsv="$work_dir/conf.tsv"
conf_errors="$work_dir/conf-errors"
: > "$conf_tsv"
: > "$conf_errors"
if [ -L "$CONF" ] || [ ! -f "$CONF" ]; then
  echo "設定のファイル scripts/harness/harness.conf がありません（シンボリックリンクも受け付けません）" >> "$conf_errors"
elif grep -q "$CR" "$CONF"; then
  echo "設定のファイルに CR（\\r）が含まれています（改行を LF にする）" >> "$conf_errors"
else
  awk -v single="$CONF_SINGLE_KEYS" -v multi="$CONF_MULTI_KEYS" -v errf="$conf_errors" '
    BEGIN {
      n = split(single, s, " "); for (i = 1; i <= n; i++) S[s[i]] = 1
      n = split(multi, m, " "); for (i = 1; i <= n; i++) M[m[i]] = 1
    }
    /^#/ { next }
    /^[ \t]*$/ { next }
    {
      e = index($0, "=")
      if (e == 0) { print NR " 行目: 「キー=値」の形ではありません" > errf; next }
      k = substr($0, 1, e - 1); v = substr($0, e + 1)
      if (k ~ /^required\.[1-9][0-9]*$/ || (k in M)) { print k "\t" v; next }
      if (k in S) {
        if (seen[k]++) { print NR " 行目: キー " k " が 2 回以上あります（1 回だけ書けるキー）" > errf; next }
        print k "\t" v; next
      }
      print NR " 行目: 知らないキー " k " があります" > errf
    }
  ' "$CONF" > "$conf_tsv"
fi

# 設定の行（conf.tsv。「キー<TAB>値」）は 1 回だけ読んで変数に持ち、キーごとの値はシェルの中で引く（キーごとに awk を
# 起動しないため）。値は、行の最初のタブより後ろのすべて（値の中のタブも含む）。
# conf.tsv が NUL を含む（awk の実装によっては設定の値の NUL をそのまま書く）と、シェルの変数には NUL の手前までしか
# 入らない。そのときは（read が NUL で止まって成功する）、キーごとに awk で引く従来の形を使う（同じ結果にするため）。
CONF_TSV_TEXT=""
CONF_TSV_NUL=0
IFS= read -r -d '' CONF_TSV_TEXT < "$conf_tsv" && CONF_TSV_NUL=1 || true
if [ "$CONF_TSV_NUL" = 1 ]; then
conf_get() { # <キー> [既定]: 1 回だけ書けるキーの値（無ければ既定）
  local v
  # キーがあれば「=」に値を続けた 1 行を出す（値が空でも、キーの有無を 1 回の awk で分けるため）
  v="$(awk -F '\t' -v k="$1" '$1 == k { sub(/^[^\t]*\t/, ""); print "=" $0; exit }' "$conf_tsv")"
  if [ -n "$v" ]; then printf '%s\n' "${v#=}"; else printf '%s\n' "${2:-}"; fi
}
conf_get_r() { REPLY="$(conf_get "$@")"; }
conf_all() { # <キー>: 何行でも書けるキーの値を 1 行に 1 つ
  awk -F '\t' -v k="$1" '$1 == k { sub(/^[^\t]*\t/, ""); print }' "$conf_tsv"
}
else
# <キー> [既定]: 1 回だけ書けるキーの値（無ければ既定）を REPLY に入れる。キーがあれば、値が空でもその値
conf_get_r() {
  local rest="$CONF_TSV_TEXT" line
  while [ -n "$rest" ]; do
    line="${rest%%"$NL"*}"
    case "$rest" in *"$NL"*) rest="${rest#*"$NL"}" ;; *) rest="" ;; esac
    if [ "${line%%"$TAB"*}" = "$1" ] && [ "$line" != "${line#*"$TAB"}" ]; then REPLY="${line#*"$TAB"}"; return 0; fi
  done
  REPLY="${2:-}"
}
conf_get() { # <キー> [既定]: 1 回だけ書けるキーの値（無ければ既定）
  local REPLY
  conf_get_r "$@"
  printf '%s\n' "$REPLY"
}
conf_all() { # <キー>: 何行でも書けるキーの値を 1 行に 1 つ
  local rest="$CONF_TSV_TEXT" line
  while [ -n "$rest" ]; do
    line="${rest%%"$NL"*}"
    case "$rest" in *"$NL"*) rest="${rest#*"$NL"}" ;; *) rest="" ;; esac
    if [ "${line%%"$TAB"*}" = "$1" ] && [ "$line" != "${line#*"$TAB"}" ]; then printf '%s\n' "${line#*"$TAB"}"; fi
  done
}
fi
conf_bad() { echo "$1" >> "$conf_errors"; }

if [ ! -s "$conf_errors" ]; then
  conf_get_r format
  [ "$REPLY" = 1 ] || conf_bad "format=1 の行がありません（設定の書式の版は 1 だけ）"
  conf_get_r agents_max_lines 120; AGENTS_MAX_LINES="$REPLY"
  [[ "$AGENTS_MAX_LINES" =~ ^[1-9][0-9]*$ ]] || conf_bad "agents_max_lines の値「${AGENTS_MAX_LINES}」が 1 以上の整数ではありません"
  conf_get_r claude_md_exact no; CLAUDE_MD_EXACT="$REPLY"
  case "$CLAUDE_MD_EXACT" in yes|no) ;; *) conf_bad "claude_md_exact の値「${CLAUDE_MD_EXACT}」が yes か no ではありません" ;; esac
  conf_get_r arch_path_prefixes 'src docs scripts .github templates'; ARCH_PREFIXES="$REPLY"
  [[ "$ARCH_PREFIXES" =~ ^[A-Za-z0-9._-]+( [A-Za-z0-9._-]+)*$ ]] \
    || conf_bad "arch_path_prefixes の値「${ARCH_PREFIXES}」が、空白 1 つで区切った名前（英数字と ._-）の並びではありません"
  conf_get_r arch_root_file_exts 'md cjs mjs ts json yml'; ARCH_EXTS="$REPLY"
  [[ "$ARCH_EXTS" =~ ^[a-z0-9]+( [a-z0-9]+)*$ ]] \
    || conf_bad "arch_root_file_exts の値「${ARCH_EXTS}」が、空白 1 つで区切った拡張子（英小文字と数字）の並びではありません"
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    [[ "$v" =~ ^[a-z0-9][a-z0-9-]*$ ]] || conf_bad "part の値「${v}」が部品の名前（英小文字・数字・ハイフン）ではありません"
  done <<EOF
$(conf_all part)
EOF
  conf_get_r default_branch main; DEFAULT_BRANCH="$REPLY"
  [[ "$DEFAULT_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "$DEFAULT_BRANCH" != -* ]] || conf_bad "default_branch の値「${DEFAULT_BRANCH}」に使えない文字があります"
  re_empty=0
  while IFS="$TAB" read -r k v; do
    case "$k" in
      required.*)
        case "$v" in
          ''|/*|*..*) conf_bad "$k の値「${v}」が、リポジトリの根からの相対のパスではありません" ;;
        esac ;;
    esac
  done < "$conf_tsv"
  # record_exempt_line_re の値が空の行があるか（タブで区切った 2 つ目の欄が空。値がタブで始まる行も当たる）
  conf_rest="$CONF_TSV_TEXT"
  if [ "$CONF_TSV_NUL" = 1 ]; then
    conf_rest=""
    awk -F '\t' '$1 == "record_exempt_line_re" && $2 == "" { f = 1 } END { exit !f }' "$conf_tsv" && re_empty=1
  fi
  while [ -n "$conf_rest" ]; do
    conf_line="${conf_rest%%"$NL"*}"
    case "$conf_rest" in *"$NL"*) conf_rest="${conf_rest#*"$NL"}" ;; *) conf_rest="" ;; esac
    case "$conf_line" in
      "record_exempt_line_re$TAB"*)
        conf_v="${conf_line#*"$TAB"}"
        [ -z "${conf_v%%"$TAB"*}" ] && re_empty=1 ;;
    esac
  done
  [ "$re_empty" = 1 ] && conf_bad "record_exempt_line_re の値が空です"
  while IFS= read -r re; do
    [ -n "$re" ] || continue
    perl -e 'my $r = eval { qr/$ARGV[0]/ }; exit 2 unless defined $r; exit 3 unless $ARGV[0] =~ /\(\?<name>/ && $ARGV[0] =~ /\(\?<ver>/; exit 0' "$re" \
      || conf_bad "record_exempt_line_re の値「${re}」が、名前つきの捕獲 (?<name>…) と (?<ver>…) を持つ perl の正規表現ではありません"
  done <<EOF
$(conf_all record_exempt_line_re)
EOF
fi
: "${AGENTS_MAX_LINES:=120}" "${CLAUDE_MD_EXACT:=no}" "${ARCH_PREFIXES:=src docs scripts .github templates}" "${DEFAULT_BRANCH:=main}"
: "${ARCH_EXTS:=md cjs mjs ts json yml}"

# 検査 7 が拾うパスの正規表現（定期の走査も --print arch-path-re で同じものを使う）
# 「.」を「\.」にする置き換えと、空白を「|」にする置き換えは、シェルの中で行う（名前ごとに sed、全体で tr を起動しない）。
# 「.」の置き換えは、${変数//…/…} の置き換えの後ろ側の逆斜線の扱いが bash の版で違うので、「.」で切ってつなぐ。
arch_path_re() {
  local p alt="" exts r q
  for p in $ARCH_PREFIXES; do
    r="$p"; q=""
    while :; do
      case "$r" in
        *.*) q="$q${r%%.*}\\."; r="${r#*.}" ;;
        *) q="$q$r"; break ;;
      esac
    done
    alt="${alt:+$alt|}$q"
  done
  exts="${ARCH_EXTS//" "/|}"
  printf '^(%s)/|^[A-Za-z0-9._-]+\\.(%s)$\n' "$alt" "$exts"
}

# 検査の短い名前（番号の順に 1 行 1 つ。1 つ目が検査 1）。名前に「、」「（」「）」と「|」を使わない
CHECK_NAMES=(
  "必須のファイル"
  "CLAUDE.md"
  "地図"
  "リンク"
  "目録"
  "行数"
  "ARCHITECTURE.md に書いたパス"
  "計画の必須の節"
  "受け入れ確認の記録"
  "製品の仕様の目録と状態"
  "古い計画"
  "検査の由来の記録"
  "写しの中身"
  "製品の機能の一覧"
)

# 追加の検査の口のファイルを、名前の順に 1 行に 1 つ出す（*.test.sh を除く）
extra_check_files() {
  local f
  for f in "$SELF_DIR/checks.d/"*.sh; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    case "$f" in *.test.sh) continue ;; esac
    printf '%s\n' "$f"
  done
}
# 追加の検査のファイル $1 の名前（「# 検査の名前: 」の行がちょうど 1 行あれば、その値）。無ければ 1 を返す
extra_check_name() {
  local n
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  n="$(grep -c '^# 検査の名前: ..*$' "$1" || true)"
  [ "$n" = 1 ] || return 1
  sed -n 's/^# 検査の名前: \(..*\)$/\1/p' "$1"
}

if [ -n "$PRINT" ]; then
  if [ -s "$conf_errors" ]; then
    sed 's/^/check-docs: NG: 設定 scripts\/harness\/harness.conf の誤り: /' "$conf_errors" >&2
    exit 2
  fi
  case "$PRINT" in
    arch-path-re) arch_path_re ;;
    conf)
      case " $CONF_SINGLE_KEYS " in
        *" $PRINT_KEY "*)
          case "$PRINT_KEY" in
            default_branch) printf '%s\n' "$DEFAULT_BRANCH" ;;
            agents_max_lines) printf '%s\n' "$AGENTS_MAX_LINES" ;;
            claude_md_exact) printf '%s\n' "$CLAUDE_MD_EXACT" ;;
            arch_path_prefixes) printf '%s\n' "$ARCH_PREFIXES" ;;
            arch_root_file_exts) printf '%s\n' "$ARCH_EXTS" ;;
            *) conf_get "$PRINT_KEY" ;;
          esac ;;
        *)
          case " $CONF_MULTI_KEYS " in
            *" $PRINT_KEY "*) conf_all "$PRINT_KEY" ;;
            *) case "$PRINT_KEY" in
                 required.[1-9]*) conf_all "$PRINT_KEY" ;;
                 *) usage_error "--print conf のキー ${PRINT_KEY} は設定のキーではありません" ;;
               esac ;;
          esac ;;
      esac ;;
    checks)
      printf '%s\n' "${CHECK_NAMES[@]}"
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        extra_check_name "$f" || true
      done <<EOF
$(extra_check_files)
EOF
      ;;
  esac
  exit 0
fi

cd -- "$ROOT"
errors=0

fail() {
  echo "check-docs: NG: $1" >&2
  echo "  直し方: $2" >&2
  errors=$((errors + 1))
}

while IFS= read -r e; do
  [ -n "$e" ] || continue
  fail "設定 scripts/harness/harness.conf の誤り: $e" \
    "設定のファイルの書き方（scripts/harness/check-docs.sh の冒頭の「設定のファイル」）に合わせて直す。値の後ろに注釈を書かない（# も値の一部になる）"
done < "$conf_errors"

# 1. 導入済みの印と、必須のファイル
if [ ! -f AGENTS.md ]; then
  fail "AGENTS.md がありません" "リポジトリのルートに AGENTS.md を置く（ハーネスの規約の正本）"
  version=""
else
  version="$(sed -n 's/^ハーネスの版: \([0-9][0-9]*\)$/\1/p' AGENTS.md | head -n 1)"
  if [ -z "$version" ]; then
    fail "AGENTS.md に導入済みの印（「ハーネスの版: N」の 1 行）がありません" \
      "AGENTS.md に「ハーネスの版: 1」の行を戻す。このプロジェクトは導入済みで、印が無いと必須のファイルの検査が働かないため"
  fi
fi

if [ -n "$version" ]; then
  required="$(conf_all "required.$version")"
  if [ -z "$required" ]; then
    fail "ハーネスの版 $version の必須のファイルの一覧がありません" \
      "scripts/harness/harness.conf に、版 $version の必須のファイルを required.$version=<パス> の行で 1 行に 1 つ足す"
  else
    while IFS= read -r path; do
      [ -z "$path" ] && continue
      case "$path" in
        */) [ -d "$path" ] || fail "必須のディレクトリ $path がありません（ハーネスの版 ${version}）" \
              "$path を作る（空なら .gitkeep を置く）。不要になったのなら、scripts/harness/harness.conf の required.<版> の行を「# 外した: <パス>（<理由>）」の注釈の行にする（検査の本体の写しは外せない）" ;;
        *) [ -f "$path" ] || fail "必須のファイル $path がありません（ハーネスの版 ${version}）" \
              "$path を戻す。不要になったのなら、scripts/harness/harness.conf の required.<版> の行を「# 外した: <パス>（<理由>）」の注釈の行にする（検査の本体の写しは外せない）" ;;
      esac
    done <<EOF
$required
EOF
  fi
fi

# 2. CLAUDE.md（CLAUDE.md があると Claude Code は AGENTS.md を自分からは読まないため）
if [ -f CLAUDE.md ]; then
  if [ "$CLAUDE_MD_EXACT" = yes ]; then
    printf '@AGENTS.md\n' | cmp -s - CLAUDE.md || fail "CLAUDE.md が「@AGENTS.md」の 1 行（末尾の改行を含む）と一致しません" \
      "CLAUDE.md を「@AGENTS.md」の 1 行にし、足したい指示は AGENTS.md に書く。CLAUDE.md があると Claude Code は AGENTS.md を自分からは読まないため"
  elif ! grep -qxF '@AGENTS.md' CLAUDE.md; then
    fail "CLAUDE.md に「@AGENTS.md」だけの行がありません" \
      "CLAUDE.md に「@AGENTS.md」だけの行を置く。新しく作るときは、この 1 行だけにし、足したい指示は AGENTS.md に書く。CLAUDE.md があると Claude Code は AGENTS.md を自分からは読まないため"
  fi
fi

# 3. 文書の地図のパス
map=""
if [ -f AGENTS.md ]; then
  map="$(awk '/^## 文書の地図/{on=1; next} /^## /{on=0} on' AGENTS.md)"
  if [ -z "$map" ]; then
    fail "AGENTS.md に「## 文書の地図」の節がありません" "AGENTS.md に、種類・パス・読む条件の表を持つ「## 文書の地図」の節を置く"
  else
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      [ -e "$p" ] || fail "文書の地図のパス $p がありません" "AGENTS.md の文書の地図を実物に合わせるか、$p を作る"
    done <<EOF
$(printf '%s\n' "$map" | grep '^|' | grep -oE '`[^`]+`' | tr -d '`' || true)
EOF
  fi
fi

# 4. Markdown の相対リンク（対応する構文は冒頭の説明のとおり）。一覧は git から NUL 区切りで得る
#    （日本語の名前を引用符付きの形にしないため）。依存の置き場などの除外は .gitignore に従う。
md_list="$work_dir/md-list"
g ls-files -z --cached --others --exclude-standard -- '*.md' > "$md_list"
# リンクの抜き出しは、一覧のすべての Markdown について 1 回の perl でまとめて行う（ファイルごとに grep を起動しないため）。
# 一覧の項目ごとに「状態 NUL 抜き出した行 NUL」を 1 組ずつ、一覧の順に書く。抜き出した行は
# grep -oE '\]\([^)[:space:]]+\)' の出力（一致ごとに 1 行。末尾の改行は除く）と同じで、状態は一致があれば 0、無ければ 1。
# 通常のファイルでない・読めない・NUL を含む（grep が中身を出さずに「Binary file」の行を出す）ものは状態 F にし、下の
# ループが、その項目だけ従来どおり grep で読む（終了コードと、grep が標準エラー出力に出す文を同じにするため）。
# perl が無ければ、すべての項目を grep で読む。
# 利用者の環境変数で perl の入出力が変わらないよう、PERL5OPT・PERLIO を空にし、-C0（PERL_UNICODE より優先）で文字の
# 変換を止め、標準入出力を :raw にする（パスとリンクをバイト列のまま扱い、grep と同じバイト列を出すため）。
md_links="$work_dir/md-links"
md_links_ok=0
if command -v perl >/dev/null 2>&1 \
  && PERL5OPT= PERLIO= perl -C0 -e '
       binmode(STDIN, ":raw"); binmode(STDOUT, ":raw");
       $/ = "\0";
       while (defined(my $p = <STDIN>)) {
         chomp $p;
         my ($st, $out) = ("F", "");
         if (!-l $p && -f _ && open(my $fh, "<:raw", $p)) {
           local $/; my $c = <$fh>; close $fh;
           if (defined $c && index($c, "\0") < 0) {
             my @m = ($c =~ /\]\([^)[:space:]]+\)/g);
             ($st, $out) = (@m ? "0" : "1", join("\n", @m));
           }
         }
         print $st, "\0", $out, "\0";
       }' < "$md_list" > "$md_links" 2>/dev/null; then
  md_links_ok=1
fi
[ "$md_links_ok" = 1 ] && exec 3< "$md_links"
while IFS= read -r -d '' md; do
  md_st=F; md_out=""
  if [ "$md_links_ok" = 1 ]; then
    IFS= read -r -d '' -u 3 md_st || md_st=F
    IFS= read -r -d '' -u 3 md_out || md_out=""
  fi
  if [ -L "$md" ]; then
    fail "$md はシンボリックリンクです" "シンボリックリンクをやめ、実体のファイルを置く"
    continue
  fi
  if [ ! -f "$md" ]; then
    # 作業ツリーで削除したファイルは調べない。それ以外で読めないものは失敗にする
    [ -n "$(g --literal-pathspecs ls-files --deleted -- "$md")" ] && continue
    fail "$md を検査できません（一覧にあるのにファイルとして読めません）" "$md の種類と読み取りの権限を確かめる"
    continue
  fi
  if [ "$md_st" = F ]; then
    set +e
    links="$(grep -oE '\]\([^)[:space:]]+\)' -- "$md")"
    rc=$?
    set -e
  else
    links="$md_out"; rc="$md_st"
  fi
  if [ "$rc" -gt 1 ]; then
    fail "$md を grep で読めません（終了コード ${rc}）" "$md の読み取りの権限と中身を確かめる"
    continue
  fi
  # $(dirname -- "$md") と同じ値をシェルの置き換えで求める（git の一覧のパスは / で終わらず、空でもないため）。ファイルごとに
  # 外のコマンドを起動しないため。コマンド置換は末尾の改行を除くので、ディレクトリの名前が改行で終わるときは同じく除く
  case "$md" in
    */*) dir="${md%/*}" ;;
    *) dir="." ;;
  esac
  while [ "${dir%"$NL"}" != "$dir" ]; do dir="${dir%"$NL"}"; done
  # grep -o が出す各行は「](」で始まり「)」で終わる。その前後を、行ごとにシェルの置き換えで外す
  while IFS= read -r target; do
    target="${target#\](}"
    target="${target%)}"
    [ -z "$target" ] && continue
    case "$target" in
      http://*|https://*|mailto:*|\#*) continue ;;
    esac
    path="${target%%#*}"
    [ -z "$path" ] && continue
    [ -e "$dir/$path" ] || fail "$md のリンク先 $target がありません" "$md のリンクを実在するパスに直す"
  done <<EOF
$links
EOF
done < "$md_list"
[ "$md_links_ok" = 1 ] && exec 3<&-

# 5. ADR の目録
if [ -f docs/adr/README.md ]; then
  for adr in docs/adr/[0-9][0-9][0-9][0-9]-*.md; do
    [ -e "$adr" ] || continue
    name="$(basename "$adr")"
    grep -qF "($name)" docs/adr/README.md || fail "ADR $name が目録 docs/adr/README.md に載っていません" \
      "docs/adr/README.md の目録の表に、[番号]($name) の行を足す"
  done
fi

# 6. AGENTS.md の行数
if [ -f AGENTS.md ]; then
  lines="$(wc -l < AGENTS.md)"
  lines="${lines//" "/}"
  if [ "$lines" -gt "$AGENTS_MAX_LINES" ]; then
    fail "AGENTS.md が $lines 行で、上限 $AGENTS_MAX_LINES 行を超えています" \
      "詳細を docs/ の文書へ移し、AGENTS.md には決まりの要約と文書の地図の行だけを残す（上限は scripts/harness/harness.conf の agents_max_lines）"
  fi
fi

# 7. ARCHITECTURE.md に書いたパス（拾う形は arch_path_re。定期の走査も同じものを使う）
if [ -f ARCHITECTURE.md ]; then
  ARCH_RE="$(arch_path_re)"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    [ -e "$p" ] || fail "ARCHITECTURE.md に書いたパス $p がありません" "ARCHITECTURE.md を実物に合わせるか、$p を作る"
  done <<EOF
$(grep -oE '`[^`]+`' ARCHITECTURE.md | tr -d '`' | grep -E "$ARCH_RE" || true)
EOF
fi

# --- 検査 8〜11 で共有する読み取り ---

# ``` で始まる行ごとに、コードブロックの中と外を切り替え、外の行だけを出す
outside_code_blocks() {
  awk '/^```/{inside=!inside; next} !inside' "$1"
}

# ファイル $1 が CR を含むか（grep -q "$CR" と同じ終了コード）。検査 8〜11 は同じ計画・記録を何度も調べるので、grep の
# 結果が「含む」（0）か「含まない」（1）のときはパスごとに覚えて、2 回目からは grep を起動しない。読めないなど grep が
# 失敗したとき（2）と、パスが改行を含むときは覚えず、毎回 grep を起動する（grep が出す文と回数を変えないため）。
CR_HAS="$NL"
CR_NOT="$NL"
has_cr() {
  local rc
  case "$1" in *"$NL"*) grep -q "$CR" "$1"; return ;; esac
  case "$CR_HAS" in *"$NL$1$NL"*) return 0 ;; esac
  case "$CR_NOT" in *"$NL$1$NL"*) return 1 ;; esac
  rc=0
  grep -q "$CR" "$1" || rc=$?
  case "$rc" in
    0) CR_HAS="$CR_HAS$1$NL" ;;
    1) CR_NOT="$CR_NOT$1$NL" ;;
  esac
  return "$rc"
}

# 書式の文書（docs/PLANS.md、docs/product-specs/README.md）の「## 必須の節」から、必須の見出しを 1 行ずつ出す。
# 読み取るのは「1. `## 目的`: 説明」の形の行の、バッククォートで囲んだ部分だけ
required_headings_of() {
  awk '/^## 必須の節$/{on=1; next} /^## /{on=0} on' "$1" | sed -n 's/^[0-9][0-9]*\. `\(## [^`]*\)`.*$/\1/p'
}

# $1 のファイルに、$2（1 行に 1 つの見出し）のうち行として無い見出しを 1 行ずつ出す。コードブロックの中の行は数えない
# 見出しごとに grep を起動せず、1 回の awk で、行として完全に一致するかを見出しの順に調べる。見出しはファイル（プロセス
# 置換）として渡す（-v は値の中の \ を解釈し、環境変数は大きいと awk を起動できなくなるため）。1 つ目のファイルかどうかは
# FILENAME で分ける（見出しが 0 行のとき、FNR == NR では本文を見出しと取り違えるため）
missing_headings_in() {
  outside_code_blocks "$1" | awk '
    FILENAME == ARGV[1] { h[++n] = $0; next }
    { present[$0] = 1 }
    END { for (i = 1; i <= n; i++) if (h[i] != "" && !(h[i] in present)) print h[i] }' <(printf '%s\n' "$2") -
}

# 計画 $1 が新しい書式の計画か（ファイル名の日付が「新しい書式の適用開始」以降か、日付で始まらない名前）。
# 適用開始の日付（format_start）を読めていないときは、どの計画も新しい書式とみなさない
is_new_format_plan() {
  local name date=""
  [ -n "${format_start:-}" ] || return 1
  # basename "$1" .md と、名前の先頭の「YYYY-MM-DD-」の日付を、外のコマンドを起動せずに求める（計画ごとに呼ぶため）
  name="${1##*/}"
  [ "$name" = .md ] || name="${name%.md}"
  case "$name" in
    *"$NL"*) # 改行を含む名前は、行ごとに読む sed のままにする（行ごとの一致を同じにするため）
      date="$(printf '%s\n' "$name" | sed -n 's/^\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)-.*$/\1/p')" ;;
    *) if [[ "$name" =~ $PLAN_DATE_PREFIX_RE ]]; then date="${BASH_REMATCH[1]}"; fi ;;
  esac
  if [ -n "$date" ] && [[ "$date" < "$format_start" ]]; then
    return 1
  fi
  return 0
}

PLAN_DATE_PREFIX_RE='^([0-9]{4}-[0-9]{2}-[0-9]{2})-'
format_start=""
if [ -f docs/PLANS.md ]; then
  format_start="$(sed -n 's/^新しい書式の適用開始: \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/\1/p' docs/PLANS.md | head -n 1)"
fi

# 8. 計画の必須の節。見出しの一覧は docs/PLANS.md の「## 必須の節」から読み取る（一覧を 2 か所に持たないため）
if [ -f docs/PLANS.md ]; then
  plan_headings="$(required_headings_of docs/PLANS.md)"
  if [ -z "$plan_headings" ]; then
    fail "docs/PLANS.md の「## 必須の節」から、計画の必須の見出しを読み取れません" \
      '「## 必須の節」の節に、「1. `## 目的`: 説明」の形で、見出しを 1 行ずつ書く'
  else
    for plan in docs/exec-plans/active/*.md docs/exec-plans/completed/*.md; do
      [ -e "$plan" ] || [ -L "$plan" ] || continue
      # 受け入れ確認の記録は計画ではない（検査 9 で調べる）
      case "$plan" in *.acceptance.md) continue ;; esac
      if [ -L "$plan" ] || [ ! -f "$plan" ]; then
        fail "計画 $plan を検査できません（シンボリックリンクか、通常のファイルではありません）" \
          "$plan を、実体のファイルとして置く"
        continue
      fi
      if has_cr "$plan"; then
        fail "計画 $plan に CR（\\r）が含まれています" "改行を LF にしてください（CR があると見出しの行が一致しないため）"
        continue
      fi
      while IFS= read -r heading; do
        [ -z "$heading" ] && continue
        fail "計画 $plan に、必須の節の見出し「${heading}」の行がありません" \
          "$plan に「${heading}」の行を足す（前後に文字を足さない）。書くことがまだ無い節も、見出しは置く（docs/PLANS.md の「必須の節」）"
      done <<EOF
$(missing_headings_in "$plan" "$plan_headings")
EOF
    done
  fi
fi

# 9. 受け入れ確認の記録（書式の正本は docs/PLANS.md の「検証の節の書式」と「受け入れ確認の記録」）

# 新しい書式の計画の検証の節を調べる。出力は 1 行ずつ、次のどれかの形:
#   ERR<TAB><問題の説明>   書式の崩れ（下の各項目）
#   ID<TAB><識別子>        検証の節の基準の識別子のすべて（確かめ方を問わない。検査 10 が使う）
#   ACC<TAB><識別子>       確かめ方が受け入れ確認の基準（検査 9 が使う）
# 確かめること: 閉じていないコードブロックが無い／「### <識別子> <題>」の識別子が重複しない／各見出しの下に
# 「- 確かめ方: <値>」の行がちょうど 1 つあり、値が「自動テスト」「受け入れ確認」「人が確認」のどれか／どの見出しの下にも
# 無い確かめ方の行が無い／「確かめ方」の語に「:」か「：」が続くのに、正しい形（行の頭が「- 確かめ方: 」）でない行が無い／
# 基準の見出しが 1 つ以上ある／受け入れ確認を含む表の行と、「確かめ方」と「受け入れ確認」を両方含むのに正しい形でない行が無い。
check_plan_verification() {
  awk '
    function end_heading() {
      if (id != "") {
        if (count == 0) print "ERR\t基準 " id " に「- 確かめ方: <値>」の行がありません"
        else if (count > 1) print "ERR\t基準 " id " に「- 確かめ方: <値>」の行が " count " 行あります（1 行にする）"
      }
      id = ""; count = 0
    }
    /^```/ { inside = !inside; next }
    inside { next }
    /^## / { if (insec) end_heading(); insec = ($0 == "## 検証（完了の条件）"); if (insec) sawsec = 1; next }
    !insec { next }
    /^###([[:space:]].*)?$/ {
      end_heading()
      nheadings++
      id = $2
      if (id == "") { print "ERR\t識別子の無い基準の見出しがあります: " $0; next }
      if (id in seen) print "ERR\t基準の識別子 " id " が重複しています"
      else print "ID\t" id
      seen[id] = 1
      next
    }
    /^- 確かめ方: / {
      v = substr($0, length("- 確かめ方: ") + 1); sub(/[[:space:]]+$/, "", v)
      if (id == "") { print "ERR\tどの「### <識別子>」の見出しの下にも無い確かめ方の行があります: " $0; next }
      count++
      if (v != "自動テスト" && v != "受け入れ確認" && v != "人が確認") {
        print "ERR\t基準 " id " の確かめ方「" v "」は、「自動テスト」「受け入れ確認」「人が確認」のどれでもありません"
      } else if (v == "受け入れ確認") {
        print "ACC\t" id
      }
      next
    }
    /確かめ方[[:space:]]*(:|：)/ { print "ERR\t形の崩れた確かめ方の行があります（「- 確かめ方: <値>」の形にする）: " $0; next }
    # 正しい形でない書き方の受け入れ確認の基準（表の行、コロンの無い確かめ方の行）。地の文と、ほかの項目の行
    # （「- 期待する結果: ...」など）で受け入れ確認に触れるだけの行は対象にしない。
    /^[[:space:]]*\|/ && index($0, "受け入れ確認") > 0 {
      print "ERR\t表の行に受け入れ確認があります（基準ごとの見出しと「- 確かめ方: 受け入れ確認」の行で書く）: " $0; next
    }
    index($0, "確かめ方") > 0 && index($0, "受け入れ確認") > 0 {
      print "ERR\t形の崩れた確かめ方の行があります（「- 確かめ方: <値>」の形にする）: " $0; next
    }
    END {
      if (insec) end_heading()
      if (sawsec && nheadings == 0) print "ERR\t基準の見出し（### <識別子> <題>）が 1 つもありません"
      if (inside) print "ERR\t閉じていないコードブロック（``` の行の数が奇数）があります"
    }
  ' "$1"
}

# 記録の書式を調べ、問題を 1 行ずつ出す。確かめること: 閉じていないコードブロックが無い／「## 」の見出しは
# 「## 実行 <番号>」だけで、番号が 1 から欠けずに 1 ずつ増える／実行が 1 つ以上ある／各実行に必須の行
# （RECORD_REQUIRED_FIELDS）がちょうど 1 行ずつあり、「確かめた対象」以外は値がある／「全体」の値が合格・不合格・未確認の
# どれか／各実行に「- 基準 <識別子>: <結果>」の行が 1 つ以上あり、各行の下に「  - 証拠: <値>」の行がある。
RECORD_REQUIRED_FIELDS="日時 確かめた者 元のコミット 分岐元 確かめた対象 基準外の所見 未確認の範囲 全体"
check_record_format() {
  awk -v fields="$RECORD_REQUIRED_FIELDS" '
    BEGIN { nreq = split(fields, req, " ") }
    function end_criterion() {
      if (pending != "") print "実行 " runno " の基準 " pending " の下に「  - 証拠: <値>」の行がありません"
      pending = ""
    }
    function end_run(   i) {
      if (!inrun) return
      end_criterion()
      for (i = 1; i <= nreq; i++) {
        if (cnt[req[i]] == 0) print "実行 " runno " に「- " req[i] ":」の行がありません"
        else if (cnt[req[i]] > 1) print "実行 " runno " に「- " req[i] ":」の行が " cnt[req[i]] " 行あります（1 行にする）"
      }
      if (ncrit == 0) print "実行 " runno " に「- 基準 <識別子>: <結果>」の行がありません"
      split("", cnt); ncrit = 0; inrun = 0
    }
    /^```/ { inside = !inside; next }
    inside { next }
    /^## / {
      end_run()
      if ($0 ~ /^## 実行 [0-9]+$/) {
        runs++
        runno = substr($0, length("## 実行 ") + 1) + 0
        if (runno != runs) print runs " 番目の実行の番号が " runno " です（番号は 1 から欠けずに 1 ずつ増やす）"
        inrun = 1
      } else {
        print "「## 実行 <番号>」でない見出しがあります: " $0
      }
      next
    }
    !inrun { next }
    /^- / {
      end_criterion()
      if ($0 ~ /^- 基準 [^ :]+: /) {
        v = substr($0, length("- 基準 ") + 1); pending = substr(v, 1, index(v, ": ") - 1); ncrit++
        next
      }
      for (i = 1; i <= nreq; i++) {
        p = "- " req[i] ":"
        if (substr($0, 1, length(p)) != p) continue
        cnt[req[i]]++
        rest = substr($0, length(p) + 1); sub(/[[:space:]]+$/, "", rest)
        if (req[i] != "確かめた対象" && rest !~ /^ ./) print "実行 " runno " の「- " req[i] ":」に値がありません"
        if (req[i] == "全体" && rest != " 合格" && rest != " 不合格" && rest != " 未確認") {
          print "実行 " runno " の全体の値「" substr(rest, 2) "」は、合格・不合格・未確認のどれでもありません"
        }
        break
      }
      next
    }
    /^[[:space:]]+- 証拠: [^[:space:]]/ { pending = ""; next }
    END {
      end_run()
      if (inside) print "閉じていないコードブロック（``` の行の数が奇数）があります"
      if (runs == 0) print "実行の節（## 実行 <番号>）がありません"
    }
  ' "$1"
}

status_table_verdict() {
  # 計画 $1 の「## 進捗」の「### 状態の表」（列「項目」「状態」「根拠」）で、基準 $2 の行（項目が $2 か「$2 (」で始まる行）を
  # 調べる。出力: exempt（状態が不合格の行があり、そのすべての根拠に空でない「持ち越し:」がある）/ no-carry（不合格の行の
  # どれかに持ち越しが無いか空）/ none（不合格の行が無い）
  outside_code_blocks "$1" | awk -v id="$2" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^## / { inprog = ($0 == "## 進捗"); intab = 0; next }
    !inprog { next }
    /^### / { intab = ($0 == "### 状態の表"); hdr = 0; ci = 0; cs = 0; cr = 0; next }
    !intab { next }
    /^\|/ {
      n = split($0, c, "|")
      if (!hdr) {
        for (i = 2; i < n; i++) { h = trim(c[i]); if (h == "項目") ci = i; else if (h == "状態") cs = i; else if (h == "根拠") cr = i }
        hdr = 1; next
      }
      if ($0 ~ /^\|[-:| ]+\|?[ \t]*$/) next
      if (!ci || !cs) next
      item = trim(c[ci])
      if (item != id && index(item, id " (") != 1) next
      if (trim(c[cs]) != "不合格") next
      fails++
      r = cr ? c[cr] : ""
      if (r ~ /持ち越し:[ \t]*[^ \t]/) ok++
      next
    }
    END { if (fails == 0) print "none"; else if (ok == fails) print "exempt"; else print "no-carry" }'
}

# 記録から、基準ごとに、判定に数える実行（確かめた者: app-evaluator）のうち最も後の実行の結果を「識別子<TAB>結果」で出す
latest_results_of() {
  outside_code_blocks "$1" | awk '
    function flush(   k) {
      if (who == "app-evaluator") for (k in cur) latest[k] = cur[k]
      split("", cur)
    }
    /^## / { flush(); inrun = ($0 ~ /^## 実行 /); who = ""; next }
    !inrun { next }
    /^- 確かめた者:/ {
      v = $0; sub(/^- 確かめた者:[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v); who = v; next
    }
    /^- 基準 / {
      v = $0; sub(/^- 基準 /, "", v)
      p = index(v, ": "); if (p == 0) next
      k = substr(v, 1, p - 1); r = substr(v, p + 2); sub(/[[:space:]]+$/, "", r)
      cur[k] = r; next
    }
    END { flush(); for (k in latest) print k "\t" latest[k] }
  '
}

if [ -f docs/PLANS.md ]; then
  if [ -z "$format_start" ]; then
    fail "docs/PLANS.md に「新しい書式の適用開始: YYYY-MM-DD」の行がありません" \
      "docs/PLANS.md の「検証の節の書式」に、新しい書式を適用し始めた日付をその形の 1 行で戻す（受け入れ確認の記録を検査する計画を決めるため）"
  fi
fi

# 9a. すべての記録: 置き場と、書いてはならないもの
for rec in docs/exec-plans/active/*.acceptance.md docs/exec-plans/completed/*.acceptance.md; do
  [ -e "$rec" ] || [ -L "$rec" ] || continue
  if [ -L "$rec" ] || [ ! -f "$rec" ]; then
    fail "受け入れ確認の記録 $rec を検査できません（シンボリックリンクか、通常のファイルではありません）" \
      "$rec を、実体のファイルとして置く"
    continue
  fi
  if has_cr "$rec"; then
    fail "受け入れ確認の記録 $rec に CR（\\r）が含まれています" "改行を LF にしてください（CR があると行を読み取れないため）"
    continue
  fi
  if grep -qE '(^|[^A-Za-z0-9._~-])/(Users|home|private|tmp|var/folders)/' "$rec"; then
    fail "受け入れ確認の記録 $rec に絶対パスの形があります" \
      "パスをリポジトリの根からの相対で書き直す。スクリーンショットはファイル名だけを書く（絶対パスにはアカウント名が入るため。docs/PLANS.md の「書いてはならないもの」）"
  fi
  rec_dir="$(dirname "$rec")"
  rec_name="$(basename "$rec" .acceptance.md)"
  if [ ! -f "$rec_dir/$rec_name.md" ]; then
    case "$rec_dir" in
      */active) other_dir="docs/exec-plans/completed" ;;
      *) other_dir="docs/exec-plans/active" ;;
    esac
    if [ -f "$other_dir/$rec_name.md" ]; then
      fail "受け入れ確認の記録 $rec が、計画 $other_dir/$rec_name.md と別のディレクトリにあります" \
        "記録を計画と同じディレクトリへ移す（計画を completed/ へ移すときは、記録も同じ変更で移す）"
    else
      fail "受け入れ確認の記録 $rec に対応する計画 $rec_dir/$rec_name.md がありません" \
        "記録の名前を計画の名前（.md を除いたもの）に .acceptance.md を付けた形に直すか、不要な記録を消す"
    fi
  fi
done

# 9b. 新しい書式の完了した計画: 受け入れ確認の基準ごとの最新の結果
if [ -n "$format_start" ]; then
  for plan in docs/exec-plans/completed/*.md; do
    case "$plan" in *.acceptance.md) continue ;; esac
    # 読めない計画と CR を含む計画は、検査 8 が失敗にしている
    { [ -f "$plan" ] && [ ! -L "$plan" ]; } || continue
    has_cr "$plan" && continue
    plan_name="$(basename "$plan" .md)"
    is_new_format_plan "$plan" || continue
    verification="$(check_plan_verification "$plan")"
    while IFS= read -r problem; do
      [ -z "$problem" ] && continue
      fail "計画 $plan の検証の節: $problem" \
        "docs/PLANS.md の「検証の節の書式」に合わせて直す（基準ごとに「### <識別子> <題>」の見出しと、その下に「- 確かめ方: <値>」の行を 1 つ）"
    done <<EOF
$(printf '%s\n' "$verification" | sed -n 's/^ERR	//p')
EOF
    criteria="$(printf '%s\n' "$verification" | sed -n 's/^ACC	//p' | sort -u)"
    rec="docs/exec-plans/completed/$plan_name.acceptance.md"
    # 記録があれば、受け入れ確認の基準の有無によらず書式を調べる
    if [ -f "$rec" ] && [ ! -L "$rec" ] && ! has_cr "$rec"; then
      while IFS= read -r problem; do
        [ -z "$problem" ] && continue
        fail "受け入れ確認の記録 $rec: $problem" \
          "docs/PLANS.md の「受け入れ確認の記録」の書式に合わせて直す。前の実行の記述は書き換えず、足りない行は新しい実行の節で確かめ直して書く"
      done <<EOF
$(check_record_format "$rec")
EOF
    fi
    [ -z "$criteria" ] && continue
    if [ ! -f "$rec" ]; then
      fail "計画 $plan に確かめ方が受け入れ確認の基準があるのに、受け入れ確認の記録 $rec がありません" \
        "受け入れ確認の担当（app-evaluator）に確かめてもらい、記録を計画と同じディレクトリに置く"
      continue
    fi
    latest="$(latest_results_of "$rec")"
    while IFS= read -r id; do
      [ -z "$id" ] && continue
      [ "$id" = "-" ] && continue
      result="$(awk -F '\t' -v k="$id" '$1 == k { print $2 }' <<<"$latest")"
      if [ "$result" != "合格" ]; then
        # 状態の表で不合格（持ち越しつき）として閉じた基準は、失敗にしない（docs/PLANS.md の状態の表の仕様）
        case "$(status_table_verdict "$plan" "$id")" in
          exempt) continue ;;
          no-carry)
            fail "計画 $plan の基準 $id は、状態の表で不合格ですが、根拠に持ち越し先がありません" \
              "不合格で閉じるには、状態の表のその行の根拠に「持ち越し: <持ち越し先>」を書く（docs/PLANS.md の状態の表の仕様）。持ち越さないなら、不具合を直して受け入れ確認の担当に基準 $id を確かめ直してもらう"
            continue ;;
        esac
      fi
      if [ -z "$result" ]; then
        fail "計画 $plan の基準 $id に、判定に数える受け入れ確認の実行がありません（記録 ${rec}）" \
          "受け入れ確認の担当（app-evaluator）に基準 $id を確かめてもらう。ほかの名前の実行は判定に数えない"
      elif [ "$result" != "合格" ]; then
        fail "計画 $plan の基準 $id の、最新の受け入れ確認の結果が「${result}」です（記録 ${rec}）" \
          "不具合を直すか確かめられなかった理由を解いてから、受け入れ確認の担当に基準 $id を確かめ直してもらう"
      fi
    done <<EOF
$criteria
EOF
  done
fi

# 10. 製品の仕様（書式と目録の正本は docs/product-specs/README.md）
SPEC_DIR="docs/product-specs"
SPEC_INDEX="$SPEC_DIR/README.md"
SPEC_FIX="docs/product-specs/README.md の書式に合わせて直す"
ABBR_RE='^[A-Z]{2,6}$'
SPEC_NAME_RE='^[a-z0-9][a-z0-9-]*\.md$'
PLAN_ID_RE='^V[0-9]+$'
catalog="$work_dir/spec-catalog.tsv"   # 略号<TAB>仕様のパス（読めなければ -）<TAB>状態
spec_ids="$work_dir/spec-ids.tsv"      # 識別子<TAB>仕様のパス
: > "$catalog"
: > "$spec_ids"
spec_dir_present=0

# 目録の表の見出しの行（列の名前と順序）。docs/product-specs/README.md の「check-docs.sh が直接読む書式」と組
CATALOG_HEADER="略号,仕様,題,状態"

# 目録（「## 目録」の節の表）を読み、1 行ずつ次の形で出す（値が空の欄は「-」にする。read で空の欄が詰まらないように）:
#   HEAD<TAB><列の名前をカンマでつないだもの>         表の 1 行目（見出しの行）
#   ROW<TAB><略号><TAB><リンク先><TAB><状態><TAB><列の数>  3 行目以降（2 行目の区切りの行は読まない）
read_spec_catalog() {
  outside_code_blocks "$1" | awk '
    function v(s) { return (s == "") ? "-" : s }
    /^## / { on = ($0 == "## 目録"); next }
    !on { next }
    /^[[:space:]]*\|/ {
      line = $0
      sub(/^[[:space:]]*\|/, "", line); sub(/\|[[:space:]]*$/, "", line)
      n = split(line, col, "|")
      for (i = 1; i <= n; i++) { gsub(/^[[:space:]]+/, "", col[i]); gsub(/[[:space:]]+$/, "", col[i]) }
      rows++
      if (rows == 1) {
        h = col[1]; for (i = 2; i <= n; i++) h = h "," col[i]
        print "HEAD\t" v(h); next
      }
      if (rows == 2 && col[1] ~ /^:?-+:?$/) next
      target = ""
      if (match(col[2], /\]\([^)]*\)/)) target = substr(col[2], RSTART + 2, RLENGTH - 3)
      print "ROW\t" v(col[1]) "\t" v(target) "\t" v(col[4]) "\t" n
    }
  '
}

# 仕様 $1 の「## 受け入れ基準」の節を調べる。$2 は目録の略号（分からなければ空）。出力は 1 行ずつ:
#   ERR<TAB><問題の説明>
#   ID<TAB><識別子>
check_spec_criteria() {
  awk -v abbr="$2" '
    BEGIN { item[1] = "- 前提:"; item[2] = "- 操作:"; item[3] = "- 期待する結果:" }
    function end_heading(   k) {
      if (id != "") {
        for (k = 1; k <= 3; k++) {
          if (cnt[k] == 0) print "ERR\t基準 " id " に「" item[k] "」の行がありません"
          else if (cnt[k] > 1) print "ERR\t基準 " id " に「" item[k] "」の行が " cnt[k] " 行あります（1 行にする）"
        }
      }
      id = ""; split("", cnt)
    }
    /^```/ { inside = !inside; next }
    inside { next }
    /^## / { if (insec) end_heading(); insec = ($0 == "## 受け入れ基準"); next }
    !insec { next }
    /^###([[:space:]].*)?$/ {
      end_heading()
      nheadings++
      id = $2
      if (id == "") { print "ERR\t識別子の無い基準の見出しがあります: " $0; id = "（識別子の無い見出し）"; next }
      if ($0 !~ /^###[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]/) {
        print "ERR\t基準 " id " の見出しに題がありません（「### <識別子> <題>」の形にする）"
      }
      if (abbr != "") {
        if (id !~ ("^" abbr "-[0-9]+$")) print "ERR\t基準の識別子 " id " が、この仕様の略号の形（" abbr "-<数字>）ではありません"
      } else if (id !~ /^[A-Z]+-[0-9]+$/) {
        print "ERR\t基準の識別子 " id " が「<略号>-<数字>」の形ではありません"
      }
      print "ID\t" id
      next
    }
    {
      for (k = 1; k <= 3; k++) if (index($0, item[k]) == 1) { if (id != "") cnt[k]++; break }
    }
    END {
      if (insec) end_heading()
      if (nheadings == 0) print "ERR\t受け入れ基準の見出し（「## 受け入れ基準」の下の ### <識別子> <題>）が 1 つもありません"
    }
  ' "$1"
}

if [ -e "$SPEC_DIR" ] || [ -L "$SPEC_DIR" ]; then
  spec_dir_present=1
  if [ -L "$SPEC_DIR" ] || [ ! -d "$SPEC_DIR" ]; then
    fail "$SPEC_DIR がディレクトリではありません" "$SPEC_DIR を、実体のディレクトリとして置く"
  elif [ -L "$SPEC_INDEX" ] || [ ! -f "$SPEC_INDEX" ]; then
    fail "$SPEC_DIR があるのに、書式と目録の文書 $SPEC_INDEX がありません" \
      "$SPEC_INDEX を実体のファイルとして置く（仕様の書式と目録の正本。仕様を置かないなら $SPEC_DIR ごと消す）"
  else
    spec_headings="$(required_headings_of "$SPEC_INDEX")"
    if [ -z "$spec_headings" ]; then
      fail "$SPEC_INDEX の「## 必須の節」から、仕様の必須の見出しを読み取れません" \
        '「## 必須の節」の節に、「1. `## 目的`: 説明」の形で、見出しを 1 行ずつ書く'
    fi

    # (1)(2)(3) 目録の行
    catalog_header=""
    while IFS="$TAB" read -r kind abbr target status ncol; do
      [ -z "$kind" ] && continue
      if [ "$kind" = HEAD ]; then
        catalog_header="$abbr"
        continue
      fi
      if [ "$ncol" != 4 ]; then
        fail "$SPEC_INDEX の目録の行（略号 ${abbr}）の列の数が $ncol です" \
          "目録の行を「| 略号 | [名前.md](名前.md) | 題 | 状態 |」の 4 列にする（題に「|」を使わない）"
      fi
      [[ "$abbr" =~ $ABBR_RE ]] || fail "$SPEC_INDEX の目録の略号 $abbr が、英大文字 2〜6 字ではありません" \
        "略号を英大文字 2〜6 字にする（受け入れ基準の識別子 <略号>-<数字> と計画の V<数字> を区別するため）"
      path="-"
      if [ "$target" = "-" ]; then
        fail "$SPEC_INDEX の目録の略号 $abbr の行に、仕様へのリンクがありません" \
          "仕様の欄を [名前.md](名前.md) のインラインのリンクにする"
      elif [[ "$target" == */* ]] || [[ "$target" != *.md ]] || [ "$target" = "README.md" ]; then
        fail "$SPEC_INDEX の目録の略号 $abbr のリンク先 $target が、$SPEC_DIR の直下の仕様のファイルではありません" \
          "仕様は $SPEC_DIR の直下に <名前>.md で置き、リンク先はファイル名だけにする"
      else
        path="$SPEC_DIR/$target"
        [[ "$target" =~ $SPEC_NAME_RE ]] || fail "$SPEC_INDEX の目録の略号 $abbr のリンク先 $target: 仕様のファイル名が英小文字・数字・ハイフンではありません" \
          "仕様のファイル名を英小文字・数字・ハイフンだけにし（英小文字か数字で始める）、目録のリンク先も合わせる"
        if [ ! -f "$path" ]; then
          fail "$SPEC_INDEX の目録の略号 $abbr のリンク先 $path がありません" \
            "目録の行を実在する仕様に直すか、仕様のファイルを置く"
          path="-"
        fi
      fi
      case "$status" in
        draft|approved|archived) ;;
        *) fail "$SPEC_INDEX の目録の略号 $abbr の状態「${status}」は、draft・approved・archived のどれでもありません" \
             "状態の欄を draft・approved・archived のどれか 1 語にする" ;;
      esac
      printf '%s\t%s\t%s\n' "$abbr" "$path" "$status" >> "$catalog"
    done <<EOF
$(read_spec_catalog "$SPEC_INDEX")
EOF
    if [ -z "$catalog_header" ]; then
      fail "$SPEC_INDEX の「## 目録」の節に、目録の表がありません" \
        "「## 目録」の節に、見出しの行が「| 略号 | 仕様 | 題 | 状態 |」の表を置く（行が 0 行でもよい）"
    elif [ "$catalog_header" != "$CATALOG_HEADER" ]; then
      fail "$SPEC_INDEX の目録の表の見出しの行が「${catalog_header}」です（期待: ${CATALOG_HEADER}）" \
        "目録の表の見出しの行を「| 略号 | 仕様 | 題 | 状態 |」に戻す。列を変えるときは scripts/harness/check-docs.sh も直す"
    fi
    while IFS= read -r dup; do
      [ -z "$dup" ] && continue
      fail "$SPEC_INDEX の目録の略号 $dup が重複しています" "略号を仕様ごとに別のものにする"
    done <<EOF
$(cut -f1 "$catalog" | sort | uniq -d)
EOF
    while IFS= read -r dup; do
      [ -z "$dup" ] && continue
      fail "$SPEC_INDEX の目録に、仕様 $dup の行が 2 行以上あります" "仕様 1 つにつき目録の行を 1 行にする"
    done <<EOF
$(cut -f2 "$catalog" | grep -vxF -- '-' | sort | uniq -d || true)
EOF

    # (2)〜(5) 仕様のファイルごと
    for spec in "$SPEC_DIR"/*.md; do
      [ -e "$spec" ] || [ -L "$spec" ] || continue
      [ "$spec" = "$SPEC_INDEX" ] && continue
      if [ -L "$spec" ] || [ ! -f "$spec" ]; then
        fail "仕様 $spec を検査できません（シンボリックリンクか、通常のファイルではありません）" "$spec を、実体のファイルとして置く"
        continue
      fi
      if grep -q "$CR" "$spec"; then
        fail "仕様 $spec に CR（\\r）が含まれています" "改行を LF にしてください（CR があると見出しの行が一致しないため）"
        continue
      fi
      [[ "$(basename "$spec")" =~ $SPEC_NAME_RE ]] || fail "仕様 $spec: 仕様のファイル名が英小文字・数字・ハイフンではありません" \
        "仕様のファイル名を英小文字・数字・ハイフンだけにし（英小文字か数字で始める）、目録のリンク先も合わせる（計画の目的の節のパスを拾う形と合わせるため）"
      abbr=""
      status=""
      row="$(awk -F '\t' -v p="$spec" '$2 == p { print; exit }' "$catalog")"
      if [ -z "$row" ]; then
        fail "仕様 $spec が目録 $SPEC_INDEX にありません" \
          "$SPEC_INDEX の「## 目録」の表に、略号・[名前.md](名前.md)・題・状態（新しい仕様は draft）の行を足す"
      else
        abbr="$(printf '%s\n' "$row" | cut -f1)"
        status="$(printf '%s\n' "$row" | cut -f3)"
        [[ "$abbr" =~ $ABBR_RE ]] || abbr=""
      fi
      spec_body="$(outside_code_blocks "$spec")"
      if grep -qE '^(- )?状態[:：]' <<<"$spec_body"; then
        fail "仕様 $spec に状態の行があります" \
          "状態の行を消す。状態は $SPEC_INDEX の目録の「状態」の列だけに持つ（2 か所に持つと食い違うため）"
      fi
      case "$status" in
        approved|archived)
          if grep -qF '[NEEDS CLARIFICATION:' <<<"$spec_body"; then
            fail "仕様 $spec は $status なのに、未決の点（[NEEDS CLARIFICATION:）が残っています" \
              "未決の点を利用者に尋ねて仕様に反映し、承認をやり直すまで目録の状態を draft に戻す"
          fi
          ;;
      esac
      criteria="$(check_spec_criteria "$spec" "$abbr")"
      # archived の仕様は、必須の節と基準の項目の書式を調べない（書式を後から変えても、過去の仕様を失敗にしないため）。
      # 識別子は集める（完了した計画が引く識別子の実在と、識別子の使い回しを確かめるため）
      if [ "$status" != archived ]; then
        if [ -n "${spec_headings:-}" ]; then
          while IFS= read -r heading; do
            [ -z "$heading" ] && continue
            fail "仕様 $spec に、必須の節の見出し「${heading}」の行がありません" \
              "$spec に「${heading}」の行を足す（前後に文字を足さない）。書くことがまだ無い節も、見出しは置く（$SPEC_INDEX の「必須の節」）"
          done <<EOF
$(missing_headings_in "$spec" "$spec_headings")
EOF
        fi
        while IFS= read -r problem; do
          [ -z "$problem" ] && continue
          fail "仕様 $spec の受け入れ基準: $problem" "${SPEC_FIX}（基準ごとに「### <略号>-<数字> <題>」と、前提・操作・期待する結果の行を 1 行ずつ）"
        done <<EOF
$(printf '%s\n' "$criteria" | sed -n 's/^ERR	//p')
EOF
      fi
      printf '%s\n' "$criteria" | sed -n 's/^ID	//p' | awk -v p="$spec" '{ print $0 "\t" p }' >> "$spec_ids"
    done
    while IFS= read -r dup; do
      [ -z "$dup" ] && continue
      fail "受け入れ基準の識別子 $dup が重複しています（重複のある仕様: $(awk -F '\t' -v k="$dup" '$1 == k { print $2 }' "$spec_ids" | sort -u | tr '\n' ' ' | sed 's/ $//')）" \
        "識別子は、仕様の略号で始め、同じ仕様の中でも仕様をまたいでも重ねない。いちど振った識別子は使い回さない"
    done <<EOF
$(cut -f1 "$spec_ids" | sort | uniq -d)
EOF
  fi
fi

# 計画 $1 が引く仕様 $2 の状態を目録で調べる。進行中の計画は approved だけ、完了した計画は approved か archived を引ける
check_plan_spec_status() {
  local plan="$1" spec="$2" status
  status="$(awk -F '\t' -v p="$spec" '$2 == p { print $3; exit }' "$catalog")"
  case "$plan" in
    docs/exec-plans/active/*)
      [ "$status" = approved ] || fail "進行中の計画 $plan が引く仕様 $spec の状態が「${status:-目録に無い}」です" \
        "進行中の計画は approved の仕様だけを引ける。利用者の承認を得て仕様を approved にしてから計画を書く（承認の前に計画を書かない）"
      ;;
    *)
      case "$status" in
        approved|archived) ;;
        *) fail "完了した計画 $plan が引く仕様 $spec の状態が「${status:-目録に無い}」です" \
             "完了した計画は approved か archived の仕様だけを引ける。仕様の状態を目録で確かめ、承認の経緯を確かめる" ;;
      esac
      ;;
  esac
}

# (6)(7) 新しい書式の計画が引く仕様（目的の節に書いた仕様と、検証の節の識別子の所属先）
for plan in docs/exec-plans/active/*.md docs/exec-plans/completed/*.md; do
  case "$plan" in *.acceptance.md) continue ;; esac
  # 読めない計画と CR を含む計画は、検査 8 が失敗にしている
  { [ -f "$plan" ] && [ ! -L "$plan" ]; } || continue
  has_cr "$plan" && continue
  is_new_format_plan "$plan" || continue
  # 仕様の名前は英小文字・数字・ハイフン（docs/product-specs/README.md の「置き場と名前」）なので、その文字だけを拾う。
  # 読点などでつないだ 2 つのパスが 1 つにつながらないようにするため
  purpose_specs="$(outside_code_blocks "$plan" | awk '/^## /{ on = ($0 == "## 目的"); next } on' \
    | { grep -oE 'docs/product-specs/[a-z0-9][a-z0-9-]*\.md' || true; } | sort -u)"
  status_checked=""
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    if awk -F '\t' -v p="$p" '$2 == p { found = 1 } END { exit !found }' "$catalog"; then
      check_plan_spec_status "$plan" "$p"
      status_checked="$status_checked
$p"
    else
      fail "計画 $plan の目的の節の仕様 $p が、目録 $SPEC_INDEX にありません" \
        "目的の節の仕様のパスを、目録の行のリンク先の仕様（docs/product-specs/<名前>.md の形）に直す"
    fi
  done <<EOF
$purpose_specs
EOF
  no_purpose_reported=0
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    [[ "$id" =~ $PLAN_ID_RE ]] && continue
    if [ "$spec_dir_present" -eq 0 ]; then
      fail "計画 $plan の基準 $id は V<数字> ではありませんが、製品の仕様の置き場 $SPEC_DIR がありません" \
        "計画の中で振る基準は V<数字> にする。製品の仕様の基準を引くなら、先に仕様を書いて承認を得る（docs/PLANS.md の「検証の節の書式」）"
      continue
    fi
    owner="$(awk -F '\t' -v k="$id" '$1 == k { print $2; exit }' "$spec_ids")"
    if [ -z "$owner" ]; then
      fail "計画 $plan の基準 $id が、どの製品の仕様の受け入れ基準にもありません" \
        "識別子を仕様の受け入れ基準の識別子に合わせるか、計画の中で振る基準なら V<数字> にする"
      continue
    fi
    if ! grep -qxF -- "$owner" <<<"$status_checked"; then
      check_plan_spec_status "$plan" "$owner"
      status_checked="$status_checked
$owner"
    fi
    if [ -z "$purpose_specs" ]; then
      if [ "$no_purpose_reported" -eq 0 ]; then
        fail "計画 $plan は製品の仕様の基準（$id など）を引くのに、目的の節に仕様のパスがありません" \
          "目的の節に、引く仕様のパスを docs/product-specs/<名前>.md の形で書く"
        no_purpose_reported=1
      fi
    elif ! grep -qxF -- "$owner" <<<"$purpose_specs"; then
      fail "計画 $plan の基準 $id は仕様 $owner の基準ですが、目的の節に書いた仕様にありません" \
        "目的の節に $owner を書くか、検証の節の識別子を目的の節に書いた仕様の基準に直す"
    fi
  done <<EOF
$(check_plan_verification "$plan" | sed -n 's/^ID	//p')
EOF
done


# 11. 古い計画（決まりの正本は docs/PLANS.md の「置き場所と名前」）
DATE_SHAPE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'

# 日付（YYYY-MM-DD）を扱う awk の関数。date コマンドの日付の計算は環境ごとに書き方が違うので、awk で計算する。
# どの awk でも同じ結果になるように、substr、int、四則と剰余だけで書く。
#   valid_date(s): 暦にある日付なら 1（月ごとの日数と、うるう年の 2 月を確かめる）
#   day_number(s): 通しの日数
DATE_AWK='
  function leap_year(y) { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }
  function valid_date(s,   y, m, d, last) {
    y = substr(s, 1, 4) + 0; m = substr(s, 6, 2) + 0; d = substr(s, 9, 2) + 0
    if (m < 1 || m > 12 || d < 1) return 0
    last = 31
    if (m == 4 || m == 6 || m == 9 || m == 11) last = 30
    if (m == 2) { if (leap_year(y)) last = 29; else last = 28 }
    return d <= last
  }
  function day_number(s,   y, m, d) {
    y = substr(s, 1, 4) + 0; m = substr(s, 6, 2) + 0; d = substr(s, 9, 2) + 0
    if (m <= 2) { y = y - 1; m = m + 12 }
    return 365 * y + int(y / 4) - int(y / 100) + int(y / 400) + int((153 * (m - 3) + 2) / 5) + d
  }
'

# $1 が、YYYY-MM-DD の形で、暦にある日付か
is_real_date() {
  [[ "$1" =~ $DATE_SHAPE_RE ]] || return 1
  awk -v s="$1" "$DATE_AWK"'BEGIN { exit !valid_date(s) }'
}

# 標準入力の各行から、YYYY-MM-DD の形の並びを 1 行に 1 つずつ出す。前か後ろに数字が続く並び（12026-10-07、
# 2026-10-071 など）は、日付でない数字の一部なので出さない
dates_in_lines() {
  awk '{
    line = $0
    while (match(line, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
      before = ""
      if (RSTART > 1) before = substr(line, RSTART - 1, 1)
      after = substr(line, RSTART + 10, 1)
      if (before !~ /[0-9]/ && after !~ /[0-9]/) print substr(line, RSTART, 10)
      line = substr(line, RSTART + 1)
    }
  }'
}

# 計画 $1 の、最も新しい日付を出す（無ければ何も出さない）。$2 = 基準の日。見るのは、ファイル名の先頭の日付と、
# 「## 進捗」の節の中の YYYY-MM-DD の形の日付。コードブロックの中の行、暦に無い日付、基準の日の 1 日後より後の日付は
# 数えない
latest_plan_date() {
  {
    basename "$1" .md | sed -n 's/^\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)-.*$/\1/p'
    outside_code_blocks "$1" | awk '/^## /{ on = ($0 == "## 進捗"); next } on' | dates_in_lines
  } | awk -v base="$2" "$DATE_AWK"'BEGIN { limit = day_number(base) + 1 } valid_date($0) && day_number($0) <= limit { print }' \
    | sort | tail -n 1
}

# latest_plan_date と、その日付から基準の日 $2 までの日数（days_between）を、1 回の awk で求めて「日付 日数」の 1 行で出す
# （日付が無ければ何も出さない）。数える日付と最も新しい日付の選び方は latest_plan_date と同じ: ファイル名の先頭の日付と、
# コードブロックの外の「## 進捗」の節の中の日付（前後に数字が続かない並び）のうち、暦にあり、基準の日の 1 日後以前のもので、
# 文字の並びとして最も大きいもの（sort | tail -n 1 と同じ。YYYY-MM-DD の形なので日付の順と同じ）。
# 計画の名前に改行を含むときは、名前の日付を行ごとに読む latest_plan_date と days_between を使う（同じ結果にするため）。
latest_plan_date_days() {
  local name fdate="" latest
  name="${1##*/}"
  [ "$name" = .md ] || name="${name%.md}"
  case "$name" in
    *"$NL"*)
      latest="$(latest_plan_date "$1" "$2")"
      [ -z "$latest" ] || printf '%s %s\n' "$latest" "$(days_between "$latest" "$2")"
      return 0 ;;
  esac
  if [[ "$name" =~ $PLAN_DATE_PREFIX_RE ]]; then fdate="${BASH_REMATCH[1]}"; fi
  awk -v base="$2" -v fdate="$fdate" "$DATE_AWK"'
    function take(s) { if (valid_date(s) && day_number(s) <= limit && (best == "" || (s "") > (best ""))) best = s }
    BEGIN { limit = day_number(base) + 1; best = ""; if (fdate != "") take(fdate) }
    /^```/ { inside = !inside; next }
    inside { next }
    /^## / { on = ($0 == "## 進捗"); next }
    on {
      line = $0
      while (match(line, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
        before = ""
        if (RSTART > 1) before = substr(line, RSTART - 1, 1)
        after = substr(line, RSTART + 10, 1)
        if (before !~ /[0-9]/ && after !~ /[0-9]/) take(substr(line, RSTART, 10))
        line = substr(line, RSTART + 1)
      }
    }
    END { if (best != "") print best " " (day_number(base) - day_number(best)) }' "$1"
}

# 日付 $1 から日付 $2 までの日数を出す（どちらも YYYY-MM-DD。$2 が後なら正の数）
days_between() {
  awk -v a="$1" -v b="$2" "$DATE_AWK"'BEGIN { print day_number(b) - day_number(a) }'
}

STALE_PLAN_DAYS=""
if [ -f docs/PLANS.md ]; then
  STALE_PLAN_DAYS="$(sed -n 's/^古い計画の日数: \([1-9][0-9]*\)$/\1/p' docs/PLANS.md | head -n 1)"
  if [ -z "$STALE_PLAN_DAYS" ]; then
    fail "docs/PLANS.md に「古い計画の日数: <整数>」の行がありません" \
      "docs/PLANS.md の「置き場所と名前」に、進行中の計画を古いとみなす日数を「古い計画の日数: 30」の形の 1 行で戻す（文書の検査の検査 11 がこの行を読む）"
  fi
fi
base_day="${HARNESS_TODAY:-$(date '+%Y-%m-%d')}"
if ! is_real_date "$base_day"; then
  fail "環境変数 HARNESS_TODAY の値「${base_day}」が、YYYY-MM-DD の形の、暦にある日付ではありません" \
    "HARNESS_TODAY を YYYY-MM-DD の形の、暦にある日付にするか、外す（外すと、実行した日を基準の日にする）"
elif [ -n "$STALE_PLAN_DAYS" ]; then
  for plan in docs/exec-plans/active/*.md; do
    case "$plan" in *.acceptance.md) continue ;; esac
    # 読めない計画と CR を含む計画は、検査 8 が失敗にしている
    { [ -f "$plan" ] && [ ! -L "$plan" ]; } || continue
    has_cr "$plan" && continue
    latest_and_days="$(latest_plan_date_days "$plan" "$base_day")"
    latest="${latest_and_days%% *}"
    if [ -z "$latest" ]; then
      fail "進行中の計画 $plan の古さを判定できません（ファイル名の先頭にも「## 進捗」の節にも、数えられる YYYY-MM-DD の形の日付がありません。暦に無い日付と、基準の日 $base_day の 1 日後より後の日付は数えない）" \
        "$plan の「## 進捗」の節に、「- YYYY-MM-DD: 終えた手順」の形で、作業を進めた日付の行を書く（docs/PLANS.md の「必須の節」の進捗の書き方）"
      continue
    fi
    elapsed="${latest_and_days#* }"
    if [ "$elapsed" -ge "$STALE_PLAN_DAYS" ]; then
      fail "進行中の計画 $plan が古くなっています（最も新しい日付 $latest から $elapsed 日。基準の日は ${base_day}。$STALE_PLAN_DAYS 日以上、日付の更新が無い進行中の計画は失敗にする）" \
        "作業を進めたなら、$plan の「## 進捗」の節に、進めた日付（YYYY-MM-DD）の行を足す。終えたなら、「## 結果と振り返り」を書いて docs/exec-plans/completed/ へ移す。やめたなら、やめた理由を「## 結果と振り返り」に書いて docs/exec-plans/completed/ へ移す（docs/PLANS.md の「置き場所と名前」）"
    fi
  done
fi

# 12. 検査の由来の記録（読み方と、調べないときは冒頭の説明のとおり）
# 地図の表の行のうち、1 列目（前後の空白を除く）が $1 の awk の正規表現に合う行の、2 列目のバッククォートの中身を 1 行に 1 つ出す
map_paths_of() {
  printf '%s\n' "$map" | awk -F '|' -v re="$1" '
    /^\|/ {
      k = $2; gsub(/^[ \t]+|[ \t]+$/, "", k)
      if (k !~ re) next
      v = $3
      while (match(v, /`[^`]+`/)) { print substr(v, RSTART + 1, RLENGTH - 2); v = substr(v, RSTART + RLENGTH) }
    }'
}
# 差分（標準入力）が、版だけを置き換えた行の対だけでできているか（設定の record_exempt_line_re を引数で受け取る）
EXEMPT_PL='
  my @res = map { qr/$_/ } @ARGV;
  # 行が規則に合えば（名前、版、行から版の部分を除いた残り）を返す。版の部分は名前つきの捕獲 ver の位置で切り出す
  sub split_ver {
    my ($l, $r) = @_;
    return () unless $l =~ $r;
    my ($n, $v) = ($+{name}, $+{ver});
    return () unless defined $n && defined $v;
    for my $k (1 .. $#-) {
      next unless defined $-[$k] && substr($l, $-[$k], $+[$k] - $-[$k]) eq $v;
      return ($n, $v, substr($l, 0, $-[$k]) . "\0" . substr($l, $+[$k]));
    }
    return ();
  }
  my ($ok, $any, $inhead) = (1, 0, 0);
  my (@minus, @plus);
  sub flush {
    if (@minus || @plus) {
      $any = 1;
      if (@minus != @plus) { $ok = 0 }
      else {
        for my $i (0 .. $#minus) {
          my ($m, $p, $pair) = ($minus[$i], $plus[$i], 0);
          for my $r (@res) {
            my ($mn, $mv, $mrest) = split_ver($m, $r); next unless defined $mn;
            my ($pn, $pv, $prest) = split_ver($p, $r); next unless defined $pn;
            if ($mn eq $pn && $mv ne $pv && $mrest eq $prest) { $pair = 1; last }
          }
          $ok = 0 unless $pair;
        }
      }
    }
    @minus = (); @plus = ();
  }
  while (my $l = <STDIN>) {
    chomp $l;
    if ($l =~ /^diff --git /) { flush(); $inhead = 1; next }
    if ($inhead) {
      if ($l =~ /^@@/) { $inhead = 0; next }
      $ok = 0 if $l =~ /^(new file mode|deleted file mode|rename from|rename to|copy from|copy to|old mode|new mode|Binary files)/;
      next;
    }
    if ($l =~ /^@@/) { flush(); next }
    next if $l =~ /^\\/;
    if ($l =~ /^-(.*)$/s) { push @minus, $1; next }
    if ($l =~ /^\+(.*)$/s) { push @plus, $1; next }
  }
  flush();
  exit(($ok && $any) ? 0 : 1);
'
if [ -n "$map" ]; then
  log_path="$(map_paths_of '^検査の由来の記録$' | head -n 1)"
  def_paths="$(map_paths_of '^検査(（|$)')"
  base_ref=""
  base_ok=1
  if [ -n "$log_path" ] && [ -n "$def_paths" ] && g rev-parse --verify -q HEAD > /dev/null; then
    if [ -n "${GITHUB_BASE_REF:-}" ]; then
      if g rev-parse --verify -q "refs/remotes/origin/$GITHUB_BASE_REF" > /dev/null; then
        base_ref="origin/$GITHUB_BASE_REF"
      else
        base_ok=0
      fi
    else
      for r in ${HARNESS_BASE_REF:+"$HARNESS_BASE_REF"} "origin/$DEFAULT_BRANCH" "$DEFAULT_BRANCH"; do
        if g rev-parse --verify -q "$r^{commit}" > /dev/null; then base_ref="$r"; break; fi
      done
    fi
    mb=""
    if [ "$base_ok" -eq 1 ] && [ -n "$base_ref" ]; then
      mb="$(g merge-base HEAD "$base_ref" 2>/dev/null)" || mb=""
      [ -n "$mb" ] || { [ -n "${GITHUB_BASE_REF:-}" ] && base_ok=0; }
    fi
    if [ "$base_ok" -eq 0 ]; then
      fail "検査の由来の記録を調べる分岐元を読めません（origin/${GITHUB_BASE_REF:-} との merge-base を求められない）" \
        "CI の checkout で履歴をすべて取得する（fetch-depth: 0）。分岐元のブランチが origin にあることを確かめる"
    elif [ -n "$mb" ] && g show "$mb:AGENTS.md" 2>/dev/null | grep -Eq '^ハーネスの版: [0-9]+$' \
      && g cat-file -e "$mb:$log_path" 2>/dev/null; then
      g diff --no-ext-diff --no-textconv --no-renames --name-only -z "$mb" -- > "$work_dir/changed.z"
      g ls-files -z --others --exclude-standard > "$work_dir/untracked.z"
      : > "$work_dir/hits"; : > "$work_dir/hits-untracked"
      for src in changed untracked; do
        while IFS= read -r -d '' f; do
          while IFS= read -r p; do
            [ -n "$p" ] || continue
            case "$p" in
              */) case "$f" in "$p"*) ;; *) continue ;; esac ;;
              *) [ "$f" = "$p" ] || continue ;;
            esac
            printf '%s\n' "$f" >> "$work_dir/hits"
            [ "$src" = untracked ] && printf '%s\n' "$f" >> "$work_dir/hits-untracked"
            break
          done <<EOF
$def_paths
EOF
        done < "$work_dir/$src.z"
      done
      if [ -s "$work_dir/hits" ]; then
        exempt=1
        [ -s "$work_dir/hits-untracked" ] && exempt=0
        rules="$(conf_all record_exempt_line_re)"
        [ -n "$rules" ] || exempt=0
        if [ "$exempt" -eq 1 ]; then
          set --
          while IFS= read -r r; do set -- "$@" "$r"; done <<EOF
$rules
EOF
          diff_args=()
          while IFS= read -r f; do diff_args[${#diff_args[@]}]="$f"; done < "$work_dir/hits"
          g diff --no-ext-diff --no-textconv --no-renames --no-color -U0 "$mb" -- "${diff_args[@]}" | perl -e "$EXEMPT_PL" "$@" || exempt=0
        fi
        if [ "$exempt" -eq 0 ]; then
          added="$(g diff --no-ext-diff --no-textconv --no-renames --no-color -U0 "$mb" -- "$log_path" | awk '
            /^\+\+\+/ { next }
            /^\+/ {
              l = substr($0, 2)
              if (l ~ /^\|/ && l !~ /^\|[-:| ]+\|?[ \t]*$/ && index(l, "元の指摘の出どころ") == 0) n++
            }
            END { print n + 0 }')"
          if [ "$added" -eq 0 ]; then
            fail "検査を定めるファイル（$(sort -u "$work_dir/hits" | tr '\n' ' ' | sed 's/ $//')）を変えたのに、検査の由来の記録 $log_path に行が足されていません（分岐元 $(g rev-parse --short "$mb")）" \
              "$log_path の記録の表に、この変更の行を 1 行足す（書き方は $log_path の「使い方」。依存やアクションの版だけを置き換える変更は、scripts/harness/harness.conf の record_exempt_line_re の形に合えば求めない）"
          fi
        fi
      fi
    fi
  fi
fi

# 13. 写しの中身（冒頭の harness-copy の行の sha256 と、冒頭の行を除いた中身の sha256 を比べる）
COPY_PL='
  use Digest::SHA qw(sha256_hex);
  my ($mode, @region_files) = @ARGV;
  sub slurp { my $f = shift; open(my $fh, "<:raw", $f) or return undef; local $/; my $c = <$fh>; close $fh; return $c }
  if ($mode eq "files") {
    local $/ = "\0";
    while (my $f = <STDIN>) {
      chomp $f;
      next if -l $f || ! -f $f;
      # 冒頭の 6 行に harness-copy の行が無いファイルは、全体を読まない
      open(my $hd, "<:raw", $f) or do { print "$f\t読めない\n"; next };
      my ($k, $has) = (0, 0);
      { local $/ = "\n"; while ($k < 6 && defined(my $x = <$hd>)) { $has = 1 if $x =~ m{^(?:#|//|<!--) harness-copy: }; $k++ } }
      close $hd;
      next unless $has;
      my $c = slurp($f);
      if (!defined $c) { print "$f\t読めない\n"; next }
      my @l = split /(?<=\n)/, $c;
      my ($i, $pre) = (0, "");
      if (@l && $l[0] =~ /^#!/) { $pre = $l[0]; $i = 1 }
      my @h;
      while ($i < @l && $l[$i] =~ m{^(?:#|//|<!--) harness-copy: }) { push @h, $l[$i]; $i++ }
      next unless @h;
      my ($want) = join("", @h) =~ m{harness-copy: sha256=([0-9a-f]{64})};
      if (!$want) { print "$f\t冒頭の harness-copy の行に sha256 が無い\n"; next }
      my $body = $pre . join("", @l[$i .. $#l]);
      print "$f\t冒頭の行を除いた中身の sha256 が、冒頭の行の値と違う\n" if sha256_hex($body) ne $want;
    }
  } else {
    for my $f (@region_files) {
      next if -l $f || ! -f $f;
      my $c = slurp($f);
      next unless defined $c;
      my @l = split /(?<=\n)/, $c;
      for (my $i = 0; $i < @l; $i++) {
        next unless $l[$i] =~ /^<!-- ([a-z0-9-]+):begin -->\n?$/;
        my $n = $1;
        next unless $i + 1 < @l && $l[$i + 1] =~ /^<!-- harness-copy: region=\Q$n\E .*sha256=([0-9a-f]{64}) -->\n?$/;
        my $want = $1;
        my ($j, $body) = ($i + 2, $l[$i]);
        while ($j < @l && $l[$j] !~ /^<!-- \Q$n\E:end -->\n?$/) { $body .= $l[$j]; $j++ }
        if ($j >= @l) { print "$f の区画 $n\t区画の終わりの印が無い\n"; next }
        $body .= $l[$j];
        print "$f の区画 $n\t区画の中身の sha256 が、harness-copy の行の値と違う\n" if sha256_hex($body) ne $want;
      }
    }
  }
'
g ls-files -z --cached --others --exclude-standard > "$work_dir/all-files.z"
md_files=()
while IFS= read -r -d '' f; do
  case "$f" in *.md) md_files[${#md_files[@]}]="$f" ;; esac
done < "$work_dir/all-files.z"
copy_problems="$( { perl -e "$COPY_PL" files < "$work_dir/all-files.z"; [ "${#md_files[@]}" -eq 0 ] || perl -e "$COPY_PL" regions "${md_files[@]}"; } )"
while IFS="$TAB" read -r what why; do
  [ -n "$what" ] || continue
  fail "写し $what の中身が合いません（${why}）" \
    "写しは手で直さない。規約の正本を直して、project-harness-init の「導入済みのプロジェクトの更新」で置き換えるか、git で元に戻す。プロジェクト専用の検査は scripts/harness/checks.d/ に置く"
done <<EOF
$copy_problems
EOF

# 14. 製品の機能の一覧（書式の正本は、製品の前提の区画 roadmap-spec。読み方は冒頭の説明のとおり）
# 文書（標準入力。コードブロックの外の行）の区画と、区画の後の「### 一覧」の表を読み、1 行ずつ次の形で出す:
#   NOREGION                     区画が無い（旧い形の文書）
#   ERR<TAB><問題の説明>          表の形の崩れ、識別子の重複、状態の値の誤り、達成の条件の形の誤り
#   ROW<TAB><識別子><TAB><状態><TAB><機能><TAB><達成の条件><TAB><根拠><TAB><基準の並び（, 区切り。無ければ ->）
# 同じ書式を、利用者単位の読み取りの道具（exec-plan の scripts/product-status.sh）も読む（2 か所で同じ例の文書を試験する）
ROADMAP_AWK='
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  function v(s) { return (s == "") ? "-" : s }
  function check_cond(c, st,   rest, p, crit, env, chk, n, a, i, it, pre) {
    CRIT = ""
    if (length(c) >= 2 && substr(c, 1, 1) == "`" && substr(c, length(c), 1) == "`") c = substr(c, 2, length(c) - 2)
    if (index(c, "基準: ") != 1) return "「基準: 」で始まらない"
    rest = substr(c, length("基準: ") + 1)
    p = index(rest, "; 環境: ")
    if (p == 0) return "「; 環境: 」が無い"
    crit = trim(substr(rest, 1, p - 1)); rest = substr(rest, p + length("; 環境: "))
    p = index(rest, "; 確かめること: ")
    if (p > 0) { env = trim(substr(rest, 1, p - 1)); chk = trim(substr(rest, p + length("; 確かめること: "))) }
    else { env = trim(rest); chk = "" }
    if (env == "" || index(env, ";") > 0) return "環境が空か、「;」で区切った余分な項目がある"
    if (p > 0 && chk == "") return "「確かめること」が空"
    if (crit == "-") {
      if (chk == "") return "基準が - なのに「確かめること」が無い"
      if (st == "済") return "基準が - の行は済にできない（仕様の基準で確かめる）"
      CRIT = "-"; return ""
    }
    n = split(crit, a, ",")
    for (i = 1; i <= n; i++) {
      it = trim(a[i])
      if (it !~ /^[A-Z]+-([0-9]+|[*])$/) return "基準の「" it "」が <略号>-<数字> か <略号>-* でない"
      pre = it; sub(/-.*$/, "", pre)
      if (length(pre) < 2 || length(pre) > 6) return "基準の「" it "」の略号が英大文字 2〜6 字でない"
      CRIT = CRIT (CRIT == "" ? "" : ",") it
    }
    if (CRIT == "") return "基準が空"
    return ""
  }
  BEGIN { phase = 0 }
  phase == 0 { if ($0 == "<!-- roadmap-spec:begin -->") phase = 1; next }
  phase == 1 { if ($0 == "<!-- roadmap-spec:end -->") phase = 2; next }
  phase == 2 { if ($0 ~ /^## /) phase = 5; else if ($0 == "### 一覧") phase = 3; next }
  phase == 3 {
    if ($0 ~ /^#+ /) { print "ERR\t「### 一覧」の下に表がありません"; phase = 5; next }
    if ($0 !~ /^[ \t]*\|/) next
    phase = 4; rows = 0
  }
  phase == 4 {
    if ($0 !~ /^[ \t]*\|/) { phase = 5; next }
    line = $0; sub(/^[ \t]*\|/, "", line); sub(/\|[ \t]*$/, "", line)
    n = split(line, col, "|")
    for (i = 1; i <= n; i++) col[i] = trim(col[i])
    rows++
    if (rows == 1) {
      h = col[1]; for (i = 2; i <= n; i++) h = h "," col[i]
      if (h != "識別子,機能,状態,達成の条件,根拠") { print "ERR\t表の見出しの行が「" h "」です（期待: 識別子,機能,状態,達成の条件,根拠）"; phase = 5 }
      next
    }
    if (rows == 2 && col[1] ~ /^:?-+:?$/) next
    if (n != 5) { print "ERR\t表の行（" col[1] "）の列の数が " n " です（5 列にする。セルに | を書かない）"; next }
    id = col[1]; st = col[3]
    if (id !~ /^F-[0-9]+$/) { print "ERR\t識別子「" id "」が F-<数字> の形ではありません"; next }
    if (id in seen) { print "ERR\t識別子 " id " が重複しています"; next }
    seen[id] = 1
    if (st != "残り" && st != "済" && st != "取りやめ") { print "ERR\t" id " の状態「" st "」は、残り・済・取りやめのどれでもありません"; next }
    if (col[2] == "") { print "ERR\t" id " の機能の名前が空です"; next }
    m = check_cond(col[4], st)
    if (m != "") { print "ERR\t" id " の達成の条件の形の誤り: " m; next }
    print "ROW\t" id "\t" st "\t" col[2] "\t" col[4] "\t" v(col[5]) "\t" CRIT
  }
  END {
    if (phase == 0) print "NOREGION"
    else if (phase == 1) print "ERR\t区画 roadmap-spec の終わりの印がありません"
    else if (phase == 3) print "ERR\t「### 一覧」の下に表がありません"
  }
'
roadmap_read() { outside_code_blocks "$1" | awk "$ROADMAP_AWK"; }
# 地図の表（標準入力）の行のうち、1 列目が $1 の awk の正規表現に合う最初の行の、2 列目のバッククォートの中身
# （書き手のパイプを途中で切らないように、入力を最後まで読む）
map_first_path_in() {
  awk -F '|' -v re="$1" '!done && /^\|/ { k = $2; gsub(/^[ \t]+|[ \t]+$/, "", k); if (k ~ re && match($3, /`[^`]+`/)) { print substr($3, RSTART + 1, RLENGTH - 2); done = 1 } }'
}
# 計画 $1 の「## 進捗」の「### 状態の表」で、基準 $2 の行（項目が $2 か「$2 (」で始まる行）の「項目<US>状態<US>根拠」を 1 行ずつ出す
# （US は \037。タブは read の IFS で続いた空欄が潰れるので、空でない区切りにして空の状態の欄を保つ）
US=$'\037'
status_rows_of() {
  outside_code_blocks "$1" | awk -v id="$2" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^## / { inprog = ($0 == "## 進捗"); intab = 0; next }
    !inprog { next }
    /^### / { intab = ($0 == "### 状態の表"); hdr = 0; ci = 0; cs = 0; cr = 0; next }
    !intab { next }
    /^\|/ {
      n = split($0, c, "|")
      if (!hdr) { for (i = 2; i < n; i++) { h = trim(c[i]); if (h == "項目") ci = i; else if (h == "状態") cs = i; else if (h == "根拠") cr = i }; hdr = 1; next }
      if ($0 ~ /^\|[-:| ]+\|?[ \t]*$/) next
      if (!ci || !cs) next
      item = trim(c[ci])
      if (item != id && index(item, id " (") != 1) next
      print item "\037" trim(c[cs]) "\037" (cr ? trim(c[cr]) : "")
    }'
}
# 計画 $1 の検証の節の「- 子項目: <識別子> = (1) (2) …」の宣言のうち、基準 $2 の子の項目（「$2 (1)」の形）を 1 行ずつ出す
children_of() {
  outside_code_blocks "$1" | awk -v id="$2" '
    /^## / { insec = ($0 ~ /^## 検証/); next }
    !insec || !/^- 子項目(:|：)/ { next }
    {
      v = $0; sub(/^- 子項目(:|：)[ \t]*/, "", v); eq = index(v, "="); if (!eq) next
      pid = substr(v, 1, eq - 1); gsub(/^[ \t`]+|[ \t`]+$/, "", pid); if (pid != id) next
      rest = substr(v, eq + 1)
      while (match(rest, /\([^()]+\)/)) { print id " " substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH) }
    }'
}
# 計画 $1 の検証の節で、基準 $2 の確かめ方が「人が確認」なら 0
human_checked_in() {
  outside_code_blocks "$1" | awk -v id="$2" '
    /^## / { insec = ($0 ~ /^## 検証/); cur = ""; next }
    !insec { next }
    /^###[ \t]/ { cur = $2; next }
    cur == id && /^- 確かめ方: 人が確認[ \t]*$/ { f = 1 }
    END { exit !f }'
}
# 文書 $1 の「持ち越し: <接頭辞>-<数字>」（全角のコロン・バッククォートも可）の識別子を 1 行に 1 つ出す。コードブロックの中は数えない
carry_ids_in() {
  outside_code_blocks "$1" | { grep -oE "持ち越し(:|：)( |　)*\`?$2-[0-9]+" || true; } | { grep -oE "$2-[0-9]+" || true; } | sort -u
}
# 分岐元（検査 12 と同じ求め方）を一度だけ求める。BASE_MB に merge-base（求めないときは空）、BASE_OK に 0（GITHUB_BASE_REF が
# あるのに求められない）か 1 を入れる
BASE_RESOLVED=0
resolve_merge_base() {
  local r base_ref=""
  [ "$BASE_RESOLVED" -eq 0 ] || return 0
  BASE_RESOLVED=1; BASE_MB=""; BASE_OK=1
  g rev-parse --verify -q HEAD > /dev/null || return 0
  if [ -n "${GITHUB_BASE_REF:-}" ]; then
    if g rev-parse --verify -q "refs/remotes/origin/$GITHUB_BASE_REF" > /dev/null; then
      base_ref="origin/$GITHUB_BASE_REF"
    else
      BASE_OK=0; return 0
    fi
  else
    for r in ${HARNESS_BASE_REF:+"$HARNESS_BASE_REF"} "origin/$DEFAULT_BRANCH" "$DEFAULT_BRANCH"; do
      if g rev-parse --verify -q "$r^{commit}" > /dev/null; then base_ref="$r"; break; fi
    done
  fi
  [ -n "$base_ref" ] || return 0
  BASE_MB="$(g merge-base HEAD "$base_ref" 2>/dev/null)" || BASE_MB=""
  if [ -z "$BASE_MB" ] && [ -n "${GITHUB_BASE_REF:-}" ]; then BASE_OK=0; fi
  return 0
}

ROADMAP_FIX="製品の前提の区画 roadmap-spec（機能の一覧）の書式に合わせて直す"
roadmap_rows="$work_dir/roadmap.tsv"   # 識別子<TAB>状態<TAB>機能<TAB>達成の条件<TAB>根拠<TAB>基準の並び
: > "$roadmap_rows"
roadmap_doc=""
roadmap_present=0
if [ -n "$map" ]; then
  roadmap_doc="$(printf '%s\n' "$map" | map_first_path_in '^製品の前提$')"
fi
if [ -n "$roadmap_doc" ] && [ -f "$roadmap_doc" ] && [ ! -L "$roadmap_doc" ] && ! grep -q "$CR" "$roadmap_doc"; then
  while IFS="$TAB" read -r kind a b c d e f; do
    case "$kind" in
      NOREGION) ;;
      ERR) fail "製品の前提 $roadmap_doc の機能の一覧: $a" "$ROADMAP_FIX" ;;
      ROW) printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$a" "$b" "$c" "$d" "$e" "$f" >> "$roadmap_rows" ;;
    esac
    [ "$kind" = NOREGION ] || roadmap_present=1
  done <<EOF
$(roadmap_read "$roadmap_doc")
EOF
  if [ "$roadmap_present" -eq 0 ] && grep -qxF '<!-- roadmap-spec:end -->' "$roadmap_doc"; then roadmap_present=1; fi
fi

# (a') 明示した基準の識別子は、状態によらず製品の仕様に実在することを求める（「-」と <略号>-* は除く。仕様に無い識別子を
# 達成の条件に書かせないため）
while IFS="$TAB" read -r rid rst rname rcond rbasis rcrit; do
  [ -n "$rid" ] && [ "$rcrit" != - ] || continue
  while IFS= read -r it; do
    case "$it" in ''|*-\*) continue ;; esac
    if ! awk -F '\t' -v k="$it" '$1 == k { f = 1 } END { exit !f }' "$spec_ids"; then
      fail "製品の前提の $rid の達成の条件の基準 $it が、製品の仕様の受け入れ基準にありません" \
        "基準の識別子を、製品の仕様にある受け入れ基準の識別子に直す（仕様がまだ無ければ、基準を - にして確かめることを書く）"
    fi
  done <<EOF2
$(printf '%s\n' "$rcrit" | tr ',' '\n')
EOF2
done < "$roadmap_rows"

# (b) 済の条件
while IFS="$TAB" read -r rid rst rname rcond rbasis rcrit; do
  [ -n "$rid" ] && [ "$rst" = 済 ] || continue
  rplans=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in *.acceptance.md) continue ;; esac
    if [ -f "$p" ] && [ ! -L "$p" ]; then rplans="$rplans$p$NL"; fi
  done <<EOF
$(printf '%s\n' "$rbasis" | { grep -oE 'docs/exec-plans/completed/[A-Za-z0-9._-]+\.md' || true; } | sort -u)
EOF
  if [ -z "$rplans" ]; then
    fail "製品の前提の $rid は済ですが、根拠に、実在する完了した計画（docs/exec-plans/completed/<名前>.md）がありません" \
      "根拠に、達成の条件の基準をすべて済にした完了した計画のパスを書く。計画を閉じたこともマージも済の証拠にしない。まだ満たしていなければ残りに戻す"
    continue
  fi
  crit_ids=""
  # 基準の並びは「,」で区切る（<略号>-* をシェルのパターンとして展開させないため、for で分けない）
  while IFS= read -r it; do
    [ -n "$it" ] || continue
    case "$it" in
      *-\*)
        ex="$(awk -F '\t' -v p="${it%\*}" 'index($1, p) == 1 { print $1 }' "$spec_ids" | sort -u)"
        if [ -z "$ex" ]; then
          fail "製品の前提の $rid の達成の条件 $it に当たる受け入れ基準が、製品の仕様にありません" \
            "略号を目録の仕様の略号に合わせるか、基準の識別子を並べて書く"
        fi
        crit_ids="$crit_ids$ex$NL" ;;
      *) crit_ids="$crit_ids$it$NL" ;;
    esac
  done <<EOF2
$(printf '%s\n' "$rcrit" | tr ',' '\n')
EOF2
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    found=0; bad=""; nodate=""; nokid=""
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      rows="$(status_rows_of "$p" "$cid")"
      [ -n "$rows" ] || continue
      found=1
      human=0; human_checked_in "$p" "$cid" && human=1
      # 子項目を宣言した基準は、宣言した子の行がすべて状態の表にあることを求める（欠けた子を済と数えないため）
      while IFS= read -r kid; do
        [ -n "$kid" ] || continue
        printf '%s\n' "$rows" | awk -F '\037' -v k="$kid" '$1 == k { f = 1 } END { exit !f }' || nokid="$nokid ${kid}（${p}）"
      done <<EOF3
$(children_of "$p" "$cid")
EOF3
      # 状態が空の行も済ではない（空の欄を飛ばさない）
      while IFS="$US" read -r it s b; do
        [ -n "$it" ] || continue
        [ "$s" = 済 ] || bad="$bad ${it}=${s:-（空）}（${p}）"
        if [ "$human" -eq 1 ] && ! printf '%s\n' "$b" | grep -qE '(^|[^0-9])[0-9]{4}-[0-9]{2}-[0-9]{2}([^0-9]|$)'; then nodate="$p"; fi
      done <<EOF2
$rows
EOF2
    done <<EOF2
$rplans
EOF2
    if [ "$found" -eq 0 ]; then
      fail "製品の前提の $rid は済ですが、根拠の完了した計画の状態の表に、基準 $cid の行がありません" \
        "基準 $cid を済にした完了した計画を根拠に書くか、まだ満たしていなければ $rid を残りに戻す"
    elif [ -n "$nokid" ]; then
      fail "製品の前提の $rid は済ですが、基準 $cid の宣言した子項目の行が状態の表にありません:${nokid}" \
        "宣言した子項目の行をすべて状態の表に置き、すべて済にしてから済にする。まだなら $rid を残りに戻す"
    elif [ -n "$bad" ]; then
      fail "製品の前提の $rid は済ですが、基準 $cid の状態の表の行が済ではありません:${bad}" \
        "不合格や未の基準がある間は済にしない。$rid を残りに戻し、理由を根拠に書く"
    elif [ -n "$nodate" ]; then
      fail "製品の前提の $rid は済ですが、人が確かめる基準 $cid の状態の表の根拠に、確かめた日付がありません（${nodate}）" \
        "状態の表の根拠に、確かめる環境で人が確かめた日付（YYYY-MM-DD）と結果を書く"
    fi
  done <<EOF2
$crit_ids
EOF2
done < "$roadmap_rows"

# (c) 計画と仕様の「持ち越し: F-<数字>」が表にあるか
carry_files=()
for p in docs/exec-plans/active/*.md docs/exec-plans/completed/*.md "$SPEC_DIR"/*.md; do
  [ -f "$p" ] && [ ! -L "$p" ] || continue
  case "$p" in *.acceptance.md|"$SPEC_INDEX") continue ;; esac
  case "$p" in
    "$SPEC_DIR"/*) [ "$(awk -F '\t' -v p="$p" '$2 == p { print $3; exit }' "$catalog")" != archived ] || continue ;;
  esac
  carry_files[${#carry_files[@]}]="$p"
done
carry_f_seen=0   # 計画か仕様に「持ち越し: F-<数字>」が 1 つでもあれば 1（機能の一覧を導入したプロジェクトの目印。(e) で使う）
for p in ${carry_files[@]+"${carry_files[@]}"}; do
  while IFS= read -r fid; do
    [ -n "$fid" ] || continue
    carry_f_seen=1
    if [ "$roadmap_present" -eq 0 ]; then
      fail "$p の持ち越し先 $fid を照らし合わせる、製品の前提の機能の一覧（区画 roadmap-spec の後の「### 一覧」の表）がありません" \
        "製品の前提を地図に載せ、機能の一覧の区画と表を置いて $fid の行を足す（利用者の決定の後）。機能の一覧を使わないなら、持ち越し先を TD-<数字>・計画のパス・issue にする"
    elif ! awk -F '\t' -v k="$fid" '$1 == k { f = 1 } END { exit !f }' "$roadmap_rows"; then
      fail "$p の持ち越し先 $fid が、製品の前提の機能の一覧にありません" \
        "利用者の決定を得て、機能の一覧に $fid の行を足すか、持ち越し先を一覧にある識別子に直す"
    fi
  done <<EOF
$(carry_ids_in "$p" F)
EOF
done

# (d) 進行中の計画の「持ち越し: TD-<数字>」が技術的負債の一覧にあるか（完了した計画は調べない。負債を解消すると行が消えるため）
td_doc=""
[ -z "$map" ] || td_doc="$(printf '%s\n' "$map" | map_first_path_in '^技術的負債の一覧$')"
[ -n "$td_doc" ] || td_doc="docs/exec-plans/tech-debt-tracker.md"
for p in docs/exec-plans/active/*.md; do
  [ -f "$p" ] && [ ! -L "$p" ] || continue
  case "$p" in *.acceptance.md) continue ;; esac
  while IFS= read -r tid; do
    [ -n "$tid" ] || continue
    if [ ! -f "$td_doc" ] || ! grep -qE "^\|[[:space:]]*$tid[[:space:]]*\|" "$td_doc"; then
      fail "進行中の計画 $p の持ち越し先 $tid が、技術的負債の一覧 $td_doc にありません" \
        "$td_doc に $tid の行を足すか、持ち越し先を一覧にある識別子に直す"
    fi
  done <<EOF
$(carry_ids_in "$p" TD)
EOF
done

# (e) 減らす変更（分岐元との比べ。分岐元の求め方は検査 12 と同じ）。比べるかは分岐元で決める: 分岐元の地図に製品の前提の行があり、
# その文書に区画があれば比べる（今の地図から行や文書を消しても、比べから外れないようにするため）
# 根拠の「利用者の決定: <場所>」の場所を 1 つずつ出す。根拠の項目は「; 」か「；」で区切る書式なので、場所はその項目の終わり
# まで（後ろの項目に書き足した証拠のパスを、新しい決定と見なさないため）。前後の空白と句点を除く。全角の文字は [] の中に書かない
decisions_of() {
  printf '%s\n' "$1" | awk '{
    n = split($0, it, /; |；/)
    for (i = 1; i <= n; i++) {
      if (!match(it[i], /利用者の決定(:|：)/)) continue
      s = substr(it[i], RSTART + RLENGTH); gsub(/^( |　)+/, "", s); gsub(/( |　|;|。)+$/, "", s)
      if (s != "") print s
    }
  }' | sort -u
}
resolve_merge_base
if [ "$BASE_OK" -eq 0 ] && [ -z "$roadmap_doc" ] && [ "$carry_f_seen" -eq 0 ]; then
  : # 機能の一覧を導入していない（地図に製品の前提の行が無く、計画と仕様に「持ち越し: F-<数字>」も無い）ので、分岐元を
    # 求められなくても比べない（検査 12 と同じ水準の割り切り。既存のプロジェクトの浅い checkout の CI を止めないため）
elif [ "$BASE_OK" -eq 0 ]; then
  fail "製品の機能の一覧を比べる分岐元を読めません（origin/${GITHUB_BASE_REF:-} との merge-base を求められない）" \
    "CI の checkout で履歴をすべて取得する（fetch-depth: 0）。分岐元のブランチが origin にあることを確かめる"
elif [ -n "$BASE_MB" ]; then
  # 分岐元に AGENTS.md が無いとき（敷く前のコミット）は、比べる文書が無いものとして扱う
  base_doc="$({ g show "$BASE_MB:AGENTS.md" 2>/dev/null || true; } | awk '/^## 文書の地図/{on=1; next} /^## /{on=0} on' | map_first_path_in '^製品の前提$')"
  if [ -n "$base_doc" ] && g show "$BASE_MB:$base_doc" > "$work_dir/roadmap-base.md" 2>/dev/null \
    && grep -qxF '<!-- roadmap-spec:end -->' "$work_dir/roadmap-base.md"; then
    # 識別子<TAB>状態<TAB>機能<TAB>達成の条件<TAB>根拠
    roadmap_read "$work_dir/roadmap-base.md" | awk -F '\t' '$1 == "ROW" { print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 }' > "$work_dir/roadmap-base.tsv"
    if [ "$roadmap_present" -eq 0 ]; then
      if [ -z "$roadmap_doc" ]; then
        where="今の地図に製品の前提の行がありません"
      else
        where="今の製品の前提 $roadmap_doc にありません"
      fi
      fail "分岐元（$(g rev-parse --short "$BASE_MB")）の製品の前提 $base_doc にあった機能の一覧の区画が、${where}" \
        "地図の製品の前提の行と、区画 roadmap-spec と「### 一覧」の表を戻す（機能の一覧は消さない。地図の製品の前提のパスを変えたときは、新しいパスの文書に区画と表を移す）"
    else
      while IFS="$TAB" read -r bid bst bname bcond bbasis; do
        [ -n "$bid" ] || continue
        cur="$(awk -F '\t' -v k="$bid" '$1 == k { print; exit }' "$roadmap_rows")"
        if [ -z "$cur" ]; then
          fail "分岐元にあった製品の前提の $bid の行が、今の機能の一覧にありません" \
            "機能の一覧の行は消さない。$bid の行を戻す（やめるときは、利用者の決定の後に状態を取りやめにし、根拠にその決定の「利用者の決定: <場所>」を足す）"
          continue
        fi
        IFS="$TAB" read -r _ cst cname ccond cbasis _ <<EOF
$cur
EOF
        why=""
        [ "$cname" = "$bname" ] || why="機能の名前を変えた"
        [ "$ccond" = "$bcond" ] || why="${why:+${why}、}達成の条件を変えた"
        if [ "$cst" = 取りやめ ] && [ "$bst" != 取りやめ ]; then why="${why:+${why}、}取りやめにした"; fi
        [ -n "$why" ] || continue
        # 変更を決めた利用者の決定の参照が、分岐元の根拠に無い形で足されていることを求める（前の決定の参照の使い回しを通さない）
        decisions_of "$bbasis" > "$work_dir/dec-base"
        decisions_of "$cbasis" > "$work_dir/dec-cur"
        if [ -z "$(comm -13 "$work_dir/dec-base" "$work_dir/dec-cur")" ]; then
          fail "製品の前提の $bid は、分岐元から${why}のに、根拠にその変更を決めた利用者の決定の参照が足されていません" \
            "利用者の決定の後だけ変える。根拠に、その変更を決めた「利用者の決定: <決めた場所>」を足すか、分岐元の値に戻す"
        fi
      done < "$work_dir/roadmap-base.tsv"
    fi
  fi
fi

# 追加の検査の口（起動元の scripts/harness/checks.d/。決まりは冒頭の説明と checks.d/README.md）
while IFS= read -r f; do
  [ -n "$f" ] || continue
  rel="scripts/harness/checks.d/$(basename "$f")"
  if [ -L "$f" ] || [ ! -f "$f" ]; then
    fail "追加の検査 $rel がシンボリックリンクか、通常のファイルではありません" "$rel を、実体のファイルとして置く"
    continue
  fi
  if ! name="$(extra_check_name "$f")"; then
    fail "追加の検査 $rel に「# 検査の名前: <短い名前>」の行がちょうど 1 行ありません" \
      "$rel の 2 行目以降の冒頭の注釈に、「# 検査の名前: <短い名前>」の行をちょうど 1 行書く（scripts/harness/checks.d/README.md）"
    continue
  fi
  set +e
  ( cd -- "$ROOT" && HARNESS_ROOT="$ROOT" HARNESS_ENGINE_DIR="$SELF_DIR" bash "$f" < /dev/null ) > "$work_dir/extra.out" 2>&1
  rc=$?
  set -e
  case "$rc" in
    0) ;;
    1)
      cat "$work_dir/extra.out" >&2
      n="$(grep -c '^check-docs: NG: ' "$work_dir/extra.out" || true)"
      [ "$n" -gt 0 ] || n=1
      errors=$((errors + n)) ;;
    *)
      fail "追加の検査 ${name}（${rel}）を実行できませんでした（終了コード ${rc}）" \
        "$rel を bash で直接実行して、出力を確かめる（終了コードは 0 が合格、1 が不合格。ほかは実行できなかったとみなす）" ;;
  esac
done <<EOF
$(extra_check_files)
EOF

# 直した後に確かめ直すコマンド（AGENTS.md の「## 検査のコマンド」の表の、1 列目が「文書（」で始まる行のもの）
docs_check_command() {
  local c=""
  if [ -f AGENTS.md ]; then
    c="$(awk '/^## /{ on = ($0 == "## 検査のコマンド"); next } on && /^\| *文書（/' AGENTS.md | head -n 1 | awk -F '|' '{ print $3 }' \
      | sed -n 's/^[^`]*`\([^`]*\)`.*$/\1/p')"
  fi
  printf '%s\n' "${c:-bash scripts/harness/check-docs.sh}"
}

if [ "$errors" -gt 0 ]; then
  echo "check-docs: $errors 件の問題があります（直した後に $(docs_check_command) で確かめ直す）" >&2
  exit 1
fi
echo "check-docs: OK（ハーネスの版 ${version}）"
