#!/usr/bin/env bash
# harness-copy: source=home/agents/skills/project-harness-init/assets/harness/drift-scan.sh
# harness-copy: version=rules-2026.11.08-1
# harness-copy: sha256=18d41ec4cd6f5d3c63f5bc87a48496df15f2f0b1f0df14cc5aeef007c2c8e9e6
# harness-copy: この 4 行と本体は手で変えない。正本を直して project-harness-init の「導入済みのプロジェクトの更新」で置き換える
# 定期の走査（drift-scan）。文書とコードのずれの材料を集めて、報告 report.md を 1 つだけ書く。ハーネスの検査の本体の写しで、
# どのプロジェクトでも同じ中身を置く。技術ごとの違い（検査の段の読み取りと実行）は、部品が置く scripts/harness/stack-adapter.sh
# （働き harness-stack）に任せ、報告を公開する前の秘匿値の確かめは、部品が置く scripts/harness/check-secrets.sh（働き
# secrets-check）に任せる。どちらも無ければ終了コード 2 で止まる。
#   手元: bash scripts/harness/drift-scan.sh --out <置き場>（相対のパスは、リポジトリの根から数える）
#   CI:   .github/workflows/drift-scan.yml（予定実行。報告を成果物に残す）
# 既定のブランチは、同じ置き場の harness.conf の default_branch（check-docs.sh --print conf default_branch で読む。無ければ main）。
#
# 走査の項目（報告の各行に、決まった形の行の識別子を付ける）:
#   1 検査の一式（1/<段の名前>）: stack-adapter.sh stages が出す段を読み取り、段ごとに stack-adapter.sh run-stage で別々に
#     実行し、失敗しても続ける。段ごとの終了コードと所要秒だけを書き、出力は書かない。段は HARNESS_TODAY を付けずに
#     実行する。終了コードが 0 でない段を要対応にする。
#   2 文書の鮮度（2/<文書のパス>）: AGENTS.md の文書の地図のうちファイルを指す行について、文書の最後の変更の日と、文書の中に
#     バッククォートで書かれた実在するパス（check-docs.sh --print arch-path-re の形）の数と、文書の最後の変更より後にそれらの
#     パスを変えたコミットの数を書く。要対応にはしない（参考）。地図のパスと文書の中のパスのうち、/ で始まるもの、
#     .. を含むもの、使えない文字を含むものは扱わない（報告に書かず、git にも渡さない）。
#   3 技術的負債の一覧（3/<TD-n>、3/表）: 各行の場所のパス、見つけた日からの日数、場所のファイルの有無、見つけた日より後に
#     場所のファイルを変えたコミットの数。場所のファイルが無い行を要対応にする。場所がバッククォートで囲んだパスでない、
#     または使えない文字を含む行は「無い（場所を読めない）」としてパスを書かない。/ で始まるか .. を含む場所は
#     「無い（リポジトリの外を指す）」として git に渡さない（パスは書くので、/ で始まるものは公開の検査で止まる）。
#     一覧の表の見出しの行（TD_HEADER）、列の数、識別子の形、見つけた日の形に合わない行があれば 3/表 を要対応にする。
#   4 品質目標の評価（4/領域:<領域>、4/層:<層>、4/表）: 「現在の評価」の各行の、評価した日からの日数と、その行の検査の
#     識別子ごとの項目 1 の結果（識別子が段に無ければ「照合しない」）。評価した日から見直しの目安の日数を超えた行と、
#     評価が A か B なのに識別子の段のどれかが失敗した行を要対応にする。表は見出しの列の名前で読む（目標の表は「検査の識別子」、
#     「現在の評価」の表は「領域」か「層」・「評価」・「検査の識別子」・「評価した日」が要り、「評価したコミット」はあれば読む。
#     ほかの列があってもよい）。「領域」の表は 1 つ要り、「層」の表は省ける。表の書式（要る列、列の数、識別子が stages の
#     SCRIPT にあること、評価が A〜D、日付が YYYY-MM-DD）に合わない行があれば、4/表 を
#     要対応にし、その行は照合しない。セルは前後の空白を除き、識別子はバッククォートを外した文字列として読む。
#     名前のセルが、使えない文字（英数字、/._:- と空白、日本語のほかの文字）を含むか長すぎる行も 4/表 に回す。
#   3 と 4 の表は共通に、見出しの直後が列の数の同じ区切り行（|---| の形）でない表、制御文字（0x00〜0x1f と 0x7f）を含む行を
#     読まずに 3/表・4/表 にする。中間のファイルで区切りに使う 0x1f で欄をずらされないよう、分けた後にも各欄の形を確かめ直す。
#     表は空白だけの行か別の塊の始まり（見出しなど。GFM の開始条件。GFM_TABLE_AWK の注釈）で終わる。表の直後に空行を
#     挟まずに続く、縦線で始まらない行は表の続きになるので、読まずに 3/表・4/表 にする（表は空行で終える）。
#   2 と 3 で読むパスは、シンボリックリンク（親ディレクトリのリンクを含む）を解決した実体がリポジトリの根の下にあるものだけ。
#   5 実行の情報（5/<項目>）: 契機（GITHUB_ACTIONS が無いときは local）、日時（UTC）、対象のコミット、間隔の日数
#     （ワークフローの注釈の行から読む）、成果物の保存期間、origin/<既定のブランチ>（走査の前に git fetch で取る）の
#     最後のコミットからの日数、試験の差し替えの有無。日数が STALE_REMOTE_DAYS（45）日以上と、試験の差し替えが「あり」を
#     要対応にする。
#
# 報告に書くのは、識別子・リポジトリの根からの相対のパス・日付・日数・数・終了コード・印だけにする。コミットの作者、
# コマンドの出力、文書の本文の抜粋、環境変数の値は書かない。報告は一時ディレクトリに書き、公開してよいかの検査（置き場に
# report.md 以外のファイルが無い、絶対パスの形・CI の作業ディレクトリと一時ディレクトリのパス・メールアドレスの形・
# 秘匿値の検査の規則に当たる値が無い、表の値が / か ~ で始まらない）を通ったときだけ --out へ移す。通らなければ報告を消して
# 終了コード 3 で終わる（どの形に当たったかだけを標準エラーに出し、値は出さない）。
#
# 終了コード: 0 = 報告を書いた（所見があっても 0）。2 = 走査を続けられない（引数の誤り、--out が空でない、git の履歴が
# 無い、段の読み取りの部品や秘匿値の検査の部品が無い、段を読めない、ワークフローの注釈と cron が合わないなど）。
# 3 = 公開してよいかの検査に通らない。
#
# 試験のための差し替え（scripts/harness/drift-scan.test.sh だけが使う。本物の実行では付けない）:
#   DRIFT_SCAN_TEST_TODAY=YYYY-MM-DD        基準の日（日数を数える日）
#   DRIFT_SCAN_TEST_STAGES="<段>=<終了コード> ..."  段を実行せず、書いた終了コードにする（書かない段は 0、所要秒は 0）
# どちらかが付いていると、報告の 5/試験の差し替え が「あり」（要対応）になる。GITHUB_ACTIONS=true のときに付いていれば、
# 差し替えが本物の実行に漏れたとみなして終了コード 2 で終わる。
# /bin/bash（macOS では 3.2）で動く書き方だけを使う。
set -euo pipefail

# 段の実行には、呼ばれたときのロケールを戻す（手元で検査の一式を流すときと同じ条件で動かすため）
ORIG_LC_ALL_SET="${LC_ALL+set}"
ORIG_LC_ALL="${LC_ALL-}"
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORKFLOW=".github/workflows/drift-scan.yml"
ADAPTER="scripts/harness/stack-adapter.sh"
SECRETS="scripts/harness/check-secrets.sh"
STALE_REMOTE_DAYS=45
MAX_RETENTION_DAYS=90

die() {
  echo "drift-scan: 走査を続けられません: $1" >&2
  exit 2
}

# --- 引数
OUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out)
      [ "$#" -ge 2 ] || die "--out の後に置き場を書いてください"
      OUT="$2"
      shift 2
      ;;
    *) die "知らない引数です（使えるのは --out <置き場> だけです）" ;;
  esac
done
[ -n "$OUT" ] || die "--out <置き場> がありません"

# --- 試験の差し替え
TEST_OVERRIDE="なし"
if [ -n "${DRIFT_SCAN_TEST_TODAY+set}" ] || [ -n "${DRIFT_SCAN_TEST_STAGES+set}" ]; then
  TEST_OVERRIDE="あり"
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    die "CI の中で、試験のための差し替えの環境変数（DRIFT_SCAN_TEST_）が付いています"
  fi
fi

cd -- "$ROOT"
g() {
  git -c core.fsmonitor=false -c core.quotePath=false "$@"
}

# --out は、無いか空のディレクトリだけを受け取る（前の報告やほかのファイルを混ぜて公開しないため）
case "$OUT" in
  /*) ;;
  *) OUT="$ROOT/$OUT" ;;
esac
if [ -e "$OUT" ] || [ -L "$OUT" ]; then
  [ -d "$OUT" ] && [ ! -L "$OUT" ] || die "--out の置き場がディレクトリではありません"
  [ -z "$(ls -A "$OUT")" ] || die "--out の置き場が空ではありません（空のディレクトリか、無い置き場を指定してください）"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 日付の計算（YYYY-MM-DD を日の通し番号にする。暦に無い日付は空を返す）
date_num() {
  awk -v d="$1" 'BEGIN {
    if (d !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) exit
    y = substr(d, 1, 4) + 0; m = substr(d, 6, 2) + 0; dd = substr(d, 9, 2) + 0
    split("31 28 31 30 31 30 31 31 30 31 30 31", ml, " ")
    if (m < 1 || m > 12 || dd < 1) exit
    lim = ml[m]
    if (m == 2 && ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0)) lim = 29
    if (dd > lim) exit
    yy = (m <= 2) ? y - 1 : y
    era = int(yy / 400); yoe = yy - era * 400
    mp = (m > 2) ? m - 3 : m + 9
    doy = int((153 * mp + 2) / 5) + dd - 1
    print era * 146097 + yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
  }'
}

if [ -n "${DRIFT_SCAN_TEST_TODAY+set}" ]; then
  TODAY="$DRIFT_SCAN_TEST_TODAY"
  NOW="${TODAY}T00:00:00Z"
else
  TODAY="$(date -u +%Y-%m-%d)"
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi
TODAY_NUM="$(date_num "$TODAY")"
[ -n "$TODAY_NUM" ] || die "基準の日が YYYY-MM-DD の形の、暦にある日付ではありません"

# 基準の日から数えた日数（暦に無い日付は空）
days_since() {
  local n
  n="$(date_num "$1")"
  if [ -n "$n" ]; then echo $((TODAY_NUM - n)); fi
}

# --- 前提: git の履歴、部品、設定、ワークフローの注釈
g rev-parse --verify -q HEAD >/dev/null || die "git の履歴がありません"
HEAD_SHA="$(g rev-parse HEAD)"

{ [ -f "$ADAPTER" ] && [ ! -L "$ADAPTER" ]; } ||
  die "段の読み取りの部品（harness-stack）がありません（${ADAPTER}。技術に合う部品を project-harness-init で足す）"
{ [ -f "$SECRETS" ] && [ ! -L "$SECRETS" ]; } ||
  die "秘匿値の検査の部品（secrets-check）がありません（${SECRETS}。報告を公開する前の確かめができないので、報告を書かない）"
# 既定のブランチは、文書の検査が読んだ設定の値を使う（設定の読み方を 1 か所にするため）
DEFAULT_BRANCH="$(bash "$HERE/check-docs.sh" --print conf default_branch 2>/dev/null)" && [ -n "$DEFAULT_BRANCH" ] \
  || die "harness.conf の default_branch を読めません（bash scripts/harness/check-docs.sh で設定の誤りを確かめる）"
case "$DEFAULT_BRANCH" in -*) die "harness.conf の default_branch が - で始まっています" ;; esac
git check-ref-format --branch "$DEFAULT_BRANCH" >/dev/null 2>&1 || die "harness.conf の default_branch がブランチの名前の形ではありません"
# 検査 7 と同じ、文書に書かれたパスを拾う形（写しを持たず、文書の検査から読む）
CHECK7_RE="$(bash "$HERE/check-docs.sh" --print arch-path-re 2>/dev/null)" && [ -n "$CHECK7_RE" ] ||
  die "文書の検査（check-docs.sh --print arch-path-re）から、パスを拾う形を読めません"
# 段の名前（SCRIPT）と、検査の一式に並ぶ段（STAGE）を、部品から読む
rc=0
bash "$ADAPTER" stages </dev/null >"$TMP/scripts.tsv" 2>/dev/null || rc=$?
[ "$rc" = 0 ] || die "段の読み取りの部品（$ADAPTER stages）が段を読めません（終了コード ${rc}。決まりは部品の文書）"
awk -F'\t' '$1 == "SCRIPT" { print $2 }' "$TMP/scripts.tsv" >"$TMP/script-names"
awk -F'\t' '$1 == "STAGE" { print $2 }' "$TMP/scripts.tsv" >"$TMP/stages"
[ -s "$TMP/stages" ] || die "段の読み取りの部品が、段を 1 つも出しません"
if grep -vE '^[A-Za-z0-9:._-]+$' "$TMP/stages" >/dev/null; then die "段の読み取りの部品が出した段の名前に、使えない文字があります"; fi

[ -f "$WORKFLOW" ] || die "ワークフローのファイル $WORKFLOW がありません"
INTERVAL="$(sed -n 's/^# 間隔の日数: \([0-9][0-9]*\)$/\1/p' "$WORKFLOW")"
[ -n "$INTERVAL" ] && [ "$(printf '%s\n' "$INTERVAL" | wc -l | tr -d ' ')" = "1" ] ||
  die "$WORKFLOW に「# 間隔の日数: <数>」の行がちょうど 1 行ありません"
cron_lines="$(grep -E '^[[:space:]]*-[[:space:]]*cron:' "$WORKFLOW" || true)"
[ -n "$cron_lines" ] && [ "$(printf '%s\n' "$cron_lines" | wc -l | tr -d ' ')" = "1" ] ||
  die "$WORKFLOW に cron の行がちょうど 1 行ありません"
cron_expr="$(printf '%s\n' "$cron_lines" | sed -n "s/^[^\"']*cron:[[:space:]]*[\"']\\([^\"']*\\)[\"'].*\$/\\1/p")"
# 間隔の日数を cron から求める。読めるのは、毎日（分 時 * * *）と毎週（分 時 * * 曜日）の形だけ
cron_days="$(printf '%s\n' "$cron_expr" | awk '
  NF == 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 == "*" && $4 == "*" {
    if ($5 == "*") print 1
    else if ($5 ~ /^[0-7]$/) print 7
  }')"
[ -n "$cron_days" ] || die "$WORKFLOW の cron を読めません（読めるのは、毎日と毎週の形だけです）"
[ "$cron_days" = "$INTERVAL" ] ||
  die "$WORKFLOW の注釈の間隔の日数（${INTERVAL}）と、cron の間隔（$cron_days 日）が合いません"

RETENTION="なし（CI の外の実行）"
if [ -n "${DRIFT_SCAN_RETENTION_DAYS:-}" ]; then
  case "$DRIFT_SCAN_RETENTION_DAYS" in
    *[!0-9]*) die "DRIFT_SCAN_RETENTION_DAYS が数ではありません" ;;
  esac
  if [ "$DRIFT_SCAN_RETENTION_DAYS" -lt 1 ] || [ "$DRIFT_SCAN_RETENTION_DAYS" -gt "$MAX_RETENTION_DAYS" ]; then
    die "DRIFT_SCAN_RETENTION_DAYS が 1〜$MAX_RETENTION_DAYS の範囲にありません"
  fi
  RETENTION="$DRIFT_SCAN_RETENTION_DAYS 日"
fi

# 契機。CI の外では local。値は決まった形の名前だけを書く
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  case "${GITHUB_EVENT_NAME:-}" in
    schedule | workflow_dispatch | pull_request) TRIGGER="$GITHUB_EVENT_NAME" ;;
    *) TRIGGER="その他" ;;
  esac
else
  TRIGGER="local"
fi
TARGET="$HEAD_SHA"
if [ "$TRIGGER" = "pull_request" ]; then
  TARGET="${HEAD_SHA}（pull request を base に合わせた試しのマージのコミット）"
fi

# origin/<既定のブランチ> の最後のコミット。取れなければ、手元の追跡ブランチを使う（それも無ければ続けない）
FETCH_NOTE=""
if ! GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" \
  g fetch --quiet --no-tags origin "$DEFAULT_BRANCH" >/dev/null 2>&1; then
  FETCH_NOTE="。git fetch に失敗したので、手元の追跡ブランチの値"
fi
g rev-parse --verify -q "refs/remotes/origin/$DEFAULT_BRANCH" >/dev/null || die "origin/$DEFAULT_BRANCH の追跡ブランチがありません"
REMOTE_DATE="$(g log -1 --format=%cs "refs/remotes/origin/$DEFAULT_BRANCH")"
REMOTE_DAYS="$(days_since "$REMOTE_DATE")"
[ -n "$REMOTE_DAYS" ] || die "origin/$DEFAULT_BRANCH の最後のコミットの日付を読めません"

# --- 報告の部品。各行は「| `<行の識別子>` | ... | <印> |」の形。要対応の行を書くたびに ATTN を 1 つ増やす
ATTN=0
# 中間のファイルの区切り（空の欄を詰めないよう、空白でない文字にする）
SEP="$(printf '\037')"

# 項目 3 と 4 の表を読む awk に前置きする関数（GFM の表の終わり方に合わせる）。
#   table_row(s): 行頭の空白が 0〜3 個の後に縦線が続く行なら 1（表の行として読む。読む前に行頭の空白を除く）
#   ends_table(s): 空白だけの行か、別の塊の始まりなら 1。別の塊は GFM の開始条件で決める（行頭の空白は 0〜3 個）:
#     ATX 見出し（# が 1〜6 個の後に空白か行の終わり。#abc は見出しでない）、引用（>）、囲み（``` で情報文字列にバッククォートが無いもの、か ~~~）、
#     区切り線（* か - か _ が 3 個以上で、間に空白があってよい）、箇条書き（- * + の後に空白）、順序付きの箇条書き
#     （数字 1〜9 桁の後に . か ) と空白）、HTML ブロックの 7 種類の開始条件（script・pre・style・textarea の開きタグ、
#     <!-- 、<? 、<! と大文字の英字、<![CDATA[ （この 2 つは大文字と小文字を区別する）、決まった名前のタグの開きか閉じ、それ以外の開きタグか閉じタグだけの行）。
#     <https://example.test> のような自動リンクは HTML ブロックではない。
#   表の中で、表の行でも ends_table でもない行は、GFM では表の続きの行になるので、表を終えずに誤りにする。
# 繰り返しの回数の指定（{n,m}）は使わない（awk の実装によって効かないため）。
GFM_TABLE_AWK='
function lead_spaces(s,   t) { t = s; sub(/^ +/, "", t); return length(s) - length(t) }
function table_row(s,   n) { n = lead_spaces(s); return n <= 3 && substr(s, n + 1, 1) == "|" }
function ends_table(s,   n, t, u, l, q, attr) {
  if (s ~ /^[ \t]*$/) return 1
  n = lead_spaces(s)
  if (n > 3) return 0
  t = substr(s, n + 1)
  if (match(t, /^#+/) && RLENGTH <= 6 && substr(t, RLENGTH + 1) ~ /^([ \t]|$)/) return 1
  if (t ~ /^>/) return 1
  # バッククォートの囲みは、情報文字列（印の後ろ）にバッククォートを含まないときだけ。チルダの囲みに、この制約は無い
  if (match(t, /^```+/) && index(substr(t, RLENGTH + 1), "`") == 0) return 1
  if (t ~ /^~~~/) return 1
  u = t; gsub(/[ \t]/, "", u)
  if (u ~ /^(\*\*\*+|---+|___+)$/) return 1
  if (t ~ /^[-*+][ \t]/) return 1
  if (match(t, /^[0-9]+/) && RLENGTH <= 9 && substr(t, RLENGTH + 1) ~ /^[.)][ \t]/) return 1
  l = tolower(t)
  if (l ~ /^<(script|pre|style|textarea)([ \t>]|$)/) return 1
  # HTML の宣言（<! の直後が大文字の英字）と CDATA は、小文字にする前の文字列で判定する（大文字と小文字を区別する）
  if (t ~ /^<!--/ || t ~ /^<\?/ || t ~ /^<![A-Z]/ || t ~ /^<!\[CDATA\[/) return 1
  if (l ~ "^</?(address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h1|h2|h3|h4|h5|h6|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|section|source|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul)([ \t>]|/>|$)") return 1
  q = sprintf("%c", 39)
  attr = "[ \t]+[a-z_:][a-z0-9_.:-]*([ \t]*=[ \t]*([^ \t\"" q "=<>`]+|" q "[^" q "]*" q "|\"[^\"]*\"))?"
  if (l ~ ("^<[a-z][a-z0-9-]*(" attr ")*[ \t]*/?>[ \t]*$")) return 1
  if (l ~ /^<\/[a-z][a-z0-9-]*[ \t]*>[ \t]*$/) return 1
  return 0
}
'

# 報告に書く値の文字の検査。許す文字（tr の集合）だけからなり、長さ（バイト）が上限以下なら 0
MAX_FIELD_BYTES=200
only_chars() { # 引数: 値、許す文字の集合
  [ -n "$1" ] && [ "${#1}" -le "$MAX_FIELD_BYTES" ] && [ -z "$(printf '%s' "$1" | tr -d "$2")" ]
}
# 品質目標の名前（英数字、/._:- と空白、日本語などの 0x80 以上のバイト）
safe_name() { only_chars "$1" 'A-Za-z0-9/._: \200-\377-'; }
# 報告に書いてよいパスの文字（英数字と「/」「.」「_」「:」「-」）
path_chars() { only_chars "$1" 'A-Za-z0-9/._:-'; }
# リポジトリの中の相対のパスとして git に渡してよいか（/ や ~ で始まらず、.. の部分を含まない）
inside_repo() {
  case "$1" in /* | "~"*) return 1 ;; esac
  case "/$1/" in */../*) return 1 ;; esac
  return 0
}
repo_path() { path_chars "$1" && inside_repo "$1"; }
# パスの実体の置き場を分ける（標準入力の各行のパスを、リポジトリの根から解決する）。出力は「状態<TAB>パス」で、状態は
# in（シンボリックリンクを親ディレクトリの分まで解決した実体が、リポジトリの根の下にある）、out（根の外にある）、
# none（無い。リンク先が無い場合を含む）。realpath のコマンドは macOS と ubuntu で有無と動きが違うので、perl で解決する
classify_paths() {
  perl -MCwd=realpath -e '
    my $root = realpath($ARGV[0]);
    while (my $p = <STDIN>) {
      chomp $p;
      next if $p eq "";
      my $st = "none";
      if (-e "$root/$p") {
        my $r = realpath("$root/$p");
        $st = (defined $r && ($r eq $root || index($r, "$root/") == 0)) ? "in" : "out";
      }
      print "$st\t$p\n";
    }' "$ROOT"
}

# --- 項目 1 検査の一式
: >"$TMP/stage-results"
# 段の差し替え（試験だけ）。ワイルドカードを展開しないよう、read -a で空白で分ける
STAGE_OVERRIDES=()
if [ -n "${DRIFT_SCAN_TEST_STAGES+set}" ]; then
  read -r -a STAGE_OVERRIDES <<<"$DRIFT_SCAN_TEST_STAGES" || true
fi
run_stage() {
  (
    if [ "$ORIG_LC_ALL_SET" = "set" ]; then export LC_ALL="$ORIG_LC_ALL"; else unset LC_ALL; fi
    unset HARNESS_TODAY
    bash "$ADAPTER" run-stage "$1"
  ) </dev/null >/dev/null 2>&1
}
while IFS= read -r stage; do
  if [ -n "${DRIFT_SCAN_TEST_STAGES+set}" ]; then
    code=0
    for kv in ${STAGE_OVERRIDES[@]+"${STAGE_OVERRIDES[@]}"}; do
      if [ "${kv%%=*}" = "$stage" ]; then code="${kv#*=}"; fi
    done
    case "$code" in
      "" | *[!0-9]*) die "DRIFT_SCAN_TEST_STAGES の終了コードが数ではありません" ;;
    esac
    secs=0
  else
    start="$(date +%s)"
    code=0
    run_stage "$stage" || code=$?
    secs=$(($(date +%s) - start))
  fi
  printf '%s\t%s\t%s\n' "$stage" "$code" "$secs" >>"$TMP/stage-results"
done <"$TMP/stages"

{
  echo "## 1 検査の一式"
  echo
  echo "| 行の識別子 | 終了コード | 所要秒 | 印 |"
  echo "|---|---|---|---|"
} >"$TMP/sec1"
while IFS="$(printf '\t')" read -r stage code secs; do
  m="参考"
  if [ "$code" != 0 ]; then
    m="要対応"
    ATTN=$((ATTN + 1))
  fi
  echo "| \`1/$stage\` | $code | $secs | $m |" >>"$TMP/sec1"
done <"$TMP/stage-results"

# --- 項目 2 文書の鮮度
{
  echo "## 2 文書の鮮度"
  echo
  echo "| 行の識別子 | 文書の最後の変更の日 | 文書に書かれた実在するパスの数 | 文書の最後の変更より後に、それらのパスを変えたコミットの数 | 印 |"
  echo "|---|---|---|---|---|"
} >"$TMP/sec2"
# 文書の地図の表の 2 列め（パス）のバッククォートの中身
: >"$TMP/map-paths"
if [ -f AGENTS.md ]; then
  awk '/^## 文書の地図/{on=1; next} /^## /{on=0} on' AGENTS.md | { grep '^|' || true; } |
    awk -F'|' '{ print $3 }' | sed -n 's/^[^`]*`\([^`]*\)`.*$/\1/p' >"$TMP/map-paths"
fi
count_commits_after() { # 引数: 基準のコミット、パス...
  local base="$1"
  shift
  g rev-list --count "$base..HEAD" -- "$@"
}
# / で始まるもの、.. を含むもの、使えない文字を含むものと、実体がリポジトリの外にあるもの（シンボリックリンクを含む）は、
# 読まず、書かない
: >"$TMP/map-safe"
while IFS= read -r doc; do
  if repo_path "$doc"; then printf '%s\n' "$doc" >>"$TMP/map-safe"; fi
done <"$TMP/map-paths"
classify_paths <"$TMP/map-safe" | awk -F'\t' '$1 == "in" { print $2 }' >"$TMP/map-in"
while IFS= read -r doc; do
  [ -f "$doc" ] || continue
  last="$(g log -1 --format='%H %cs' -- "$doc" || true)"
  { grep -oE '`[^`]+`' -- "$doc" || true; } | tr -d '`' | { grep -E "$CHECK7_RE" || true; } | sort -u >"$TMP/doc-paths"
  : >"$TMP/doc-safe"
  while IFS= read -r p; do
    if repo_path "$p"; then printf '%s\n' "$p" >>"$TMP/doc-safe"; fi
  done <"$TMP/doc-paths"
  # 実体がリポジトリの根の下にある、実在のパスだけを数える
  classify_paths <"$TMP/doc-safe" | awk -F'\t' '$1 == "in" { print $2 }' >"$TMP/doc-in"
  set --
  while IFS= read -r p; do
    if [ -e "$p" ]; then set -- "$@" "$p"; fi
  done <"$TMP/doc-in"
  n="$#"
  if [ -z "$last" ]; then
    date_s="未コミット"
    after="-"
  else
    date_s="${last#* }"
    if [ "$n" -gt 0 ]; then after="$(count_commits_after "${last%% *}" "$@")"; else after=0; fi
  fi
  echo "| \`2/$doc\` | $date_s | $n | $after | 参考 |" >>"$TMP/sec2"
done <"$TMP/map-in"

# --- 項目 3 技術的負債の一覧
TRACKER="docs/exec-plans/tech-debt-tracker.md"
TD_HEADER='| 識別子 | 見つけた日 | 場所 | 内容 | 見つけた作業 |'
{
  echo "## 3 技術的負債の一覧"
  echo
  echo "| 行の識別子 | 場所 | 見つけた日からの日数 | 場所のファイル | 見つけた日より後に場所のファイルを変えたコミットの数 | 印 |"
  echo "|---|---|---|---|---|---|"
} >"$TMP/sec3"
# 出力: ERR\t<行>\t<理由> / ROW<区切り><識別子><区切り><見つけた日><区切り><場所のセル><区切り><行>
if [ -f "$TRACKER" ]; then
  awk -v h="$TD_HEADER" -v sep="$SEP" "$GFM_TABLE_AWK"'
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^## / { sec = $0; intable = 0; next }
    sec != "## 一覧" { next }
    table_row($0) {
      line = $0; sub(/^ +/, "", line); sub(/[ \t]+$/, "", line)
      if (!intable) { intable = 1; tables++; rowno = 0; bad = 0; hcols = split(line, hc, "|") - 2
        if (line != h) { bad = 1; printf "ERR\t%d\t見出しの行が決まった形と違う\n", FNR }
        next }
      rowno++
      if (bad) next
      # 見出しの直後は、列の数が見出しと同じ区切り行（|---| の形）でなければならない
      if (rowno == 1) {
        if (line !~ /^\|( *:?-+:? *\|)+$/ || split(line, sc, "|") - 2 != hcols) {
          bad = 1; printf "ERR\t%d\t見出しの直後が区切り行でない\n", FNR }
        next }
      # 制御文字（中間のファイルの区切りを含む）のある行は読まない
      if (line ~ /[[:cntrl:]]/) { printf "ERR\t%d\t制御文字がある\n", FNR; next }
      n = split(line, c, "|")
      if (n - 2 != 5) { printf "ERR\t%d\t列の数が違う\n", FNR; next }
      id = trim(c[2])
      if (id !~ /^TD-[0-9]+$/) { printf "ERR\t%d\t識別子が TD-<数> の形でない\n", FNR; next }
      print "ROW" sep id sep trim(c[3]) sep trim(c[4]) sep FNR
      next }
    intable && !ends_table($0) { printf "ERR\t%d\t表の行が縦線で始まらない（表は空行で終える）\n", FNR; next }
    { intable = 0 }
    END { if (tables != 1) print "ERR\t0\t「## 一覧」の節に表がちょうど 1 つない" }
  ' "$TRACKER" >"$TMP/td-raw"
else
  printf 'ERR\t0\t技術的負債の一覧が無い\n' >"$TMP/td-raw"
fi
awk -F'\t' '$1 == "ERR" { print $2 "\t" $3 }' "$TMP/td-raw" >"$TMP/td-err"
td_count=0
while IFS="$SEP" read -r tag id found loc lineno extra; do
  [ "$tag" = "ROW" ] || continue
  # 分けた後に、各欄の形を確かめ直す（区切りがずれていたら読まない）
  if [ -n "$extra" ] || ! printf '%s' "$id" | grep -Eq '^TD-[0-9]+$' || ! printf '%s' "$lineno" | grep -Eq '^[0-9]+$'; then
    printf '%s\t%s\n' "0" "行の欄を分けられない" >>"$TMP/td-err"
    continue
  fi
  td_count=$((td_count + 1))
  days="$(days_since "$found")"
  if [ -z "$days" ]; then
    days="日付を読めない"
    printf '%s\t%s\n' "$lineno" "見つけた日が YYYY-MM-DD の形の、暦にある日付でない" >>"$TMP/td-err"
  fi
  path="$(printf '%s\n' "$loc" | sed -n 's/^[^`]*`\([^`]*\)`.*$/\1/p')"
  after="-"
  m="要対応"
  if ! path_chars "$path"; then
    # バッククォートで囲んだパスが無いか、報告に書けない文字を含む。パスは書かない
    state="無い（場所を読めない）"
    path="-"
  elif ! inside_repo "$path"; then
    # リポジトリの外を指すので git に渡さない。パスは書く（/ で始まるものは、公開の検査で止まる）
    state="無い（リポジトリの外を指す）"
  elif [ "$(printf '%s\n' "$path" | classify_paths | cut -f1)" = "out" ]; then
    # シンボリックリンク（親ディレクトリを含む）を解決すると、リポジトリの外にある。読まない
    state="無い（リポジトリの外を指す）"
  elif [ -e "$path" ]; then
    state="ある"
    m="参考"
    if [ "$days" != "日付を読めない" ]; then
      after="$(g log --format=%cs -- "$path" | awk -v f="$found" '$0 > f' | wc -l | tr -d ' ')"
    fi
  else
    state="無い"
  fi
  [ "$m" = "要対応" ] && ATTN=$((ATTN + 1))
  echo "| \`3/$id\` | \`$path\` | $days | $state | $after | $m |" >>"$TMP/sec3"
done <"$TMP/td-raw"
[ "$td_count" -gt 0 ] || echo "| \`3/なし\` | - | - | - | - | 参考 |" >>"$TMP/sec3"
if [ -s "$TMP/td-err" ]; then
  ATTN=$((ATTN + 1))
  why="$(sort -n "$TMP/td-err" | awk -F'\t' '{ printf "%s%s%s", (NR > 1 ? "。" : ""), ($1 == 0 ? "" : $1 " 行: "), $2 }')"
  echo "| \`3/表\` | - | - | 技術的負債の一覧の表を読めない（${why}） | - | 要対応 |" >>"$TMP/sec3"
fi

# --- 項目 4 品質目標の評価
QS="docs/QUALITY_SCORE.md"
: >"$TMP/qs"
if [ -f "$QS" ]; then
  # 出力: REVIEW\t<日数> / ERR\t<行>\t<理由> / ROW<区切り><領域|層><区切り><名前><区切り><評価><区切り>
  #       <識別子をコンマで><区切り><日付><区切り><コミット（列が無ければ -）><区切り><行>
  #       （識別子は空のことがあるので、ROW だけ区切りを SEP にする）。表は見出しの列の名前で読む
  awk -v sep="$SEP" "$GFM_TABLE_AWK"'
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function err(msg) { printf "ERR\t%d\t%s\n", FNR, msg }
    # 識別子のセルを読む。正しければコンマで区切った識別子（- のときは空）、誤りなら "!"
    function ids(cell,   n, parts, i, x, out) {
      cell = trim(cell)
      if (cell == "-") return ""
      n = split(cell, parts, ",")
      out = ""
      for (i = 1; i <= n; i++) {
        x = trim(parts[i])
        if (x ~ /^`[^`]+`$/) x = substr(x, 2, length(x) - 2)
        x = trim(x)
        if (x !~ /^[A-Za-z0-9:._-]+$/ || !(x in scripts)) return "!"
        out = out (out == "" ? "" : ",") x
      }
      return out
    }
    NR == FNR { scripts[$0] = 1; next }
    /^## / { sec = $0; intable = 0; next }
    table_row($0) {
      line = $0; sub(/^ +/, "", line); sub(/[ \t]+$/, "", line)
      if (!intable) { intable = 1; header = line; rowno = 0; hcols = split(line, hc, "|") - 2
        delete col
        for (i = 2; i <= hcols + 1; i++) { x = trim(hc[i]); if (x != "" && !(x in col)) col[x] = i }
        if (sec == "## 目標") { goalseen = 1; kind = ("検査の識別子" in col) ? "goal" : "bad"
          if (kind == "bad") err("目標の表に「検査の識別子」の列が無い") }
        else if (sec == "## 現在の評価") {
          if ("領域" in col) { kind = "t1"; t1seen++; cn = col["領域"] }
          else if ("層" in col) { kind = "t2"; cn = col["層"] }
          else { kind = "bad"; err("現在の評価の表に「領域」か「層」の列が無い") }
          if (kind != "bad") {
            if (!("評価" in col) || !("検査の識別子" in col) || !("評価した日" in col)) {
              kind = "bad"; err("現在の評価の表に「評価」「検査の識別子」「評価した日」の列のどれかが無い")
            } else { cr = col["評価"]; ci = col["検査の識別子"]; cd = col["評価した日"]; cc = ("評価したコミット" in col) ? col["評価したコミット"] : 0 }
          }
        } else kind = "other"
        next }
      rowno++
      if (kind == "bad" || kind == "other") next
      # 見出しの直後は、列の数が見出しと同じ区切り行（|---| の形）でなければならない
      if (rowno == 1) {
        if (line !~ /^\|( *:?-+:? *\|)+$/ || split(line, sc, "|") - 2 != hcols) {
          kind = "bad"; err("表の見出しの直後が区切り行でない") }
        next }
      # 制御文字（中間のファイルの区切りを含む）のある行は読まない
      if (line ~ /[[:cntrl:]]/) { err("表の行に制御文字がある"); next }
      n = split(line, c, "|"); cols = n - 2
      if (cols != hcols) { err("表の列の数が見出しと違う"); next }
      if (kind == "goal") {
        if (ids(c[col["検査の識別子"]]) == "!") err("目標の表の識別子が段の名前に無いか、書き方が違う")
        next }
      name = trim(c[cn]); gsub(/`/, "", name); name = trim(name)
      rating = trim(c[cr]); idl = ids(c[ci]); d = trim(c[cd]); cm = cc ? trim(c[cc]) : "-"
      if (name == "") { err("現在の評価の表の名前のセルが空"); next }
      if (rating !~ /^[ABCD]$/) { err("現在の評価の表の評価が A〜D でない"); next }
      if (idl == "!") { err("現在の評価の表の識別子が段の名前に無いか、書き方が違う"); next }
      if (d !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) { err("現在の評価の表の評価した日が YYYY-MM-DD でない"); next }
      if (cc && (cm !~ /^[0-9a-f]+$/ || length(cm) < 7 || length(cm) > 40)) { err("現在の評価の表の評価したコミットが 16 進の 7〜40 字でない"); next }
      printf "ROW%s%s%s%s%s%s%s%s%s%s%s%s%s%d\n", sep, (kind == "t1" ? "領域" : "層"), sep, name, sep, rating, sep, idl, sep, d, sep, cm, sep, FNR
      next }
    # 表の直後に空行を挟まずに続く行（「見直しの目安」の行を含む）は表の続きなので、読まずに誤りにする
    intable && !ends_table($0) { err("表の行が縦線で始まらない（表は空行で終える）"); next }
    { intable = 0
      if (sec == "## 現在の評価" && $0 ~ /^見直しの目安: [0-9]+ 日[ \t]*$/) {
        v = $0; sub(/^見直しの目安: /, "", v); sub(/ 日.*$/, "", v); review = v; reviewcount++ } }
    END {
      if (!goalseen) print "ERR\t0\t目標の表が無い"
      if (t1seen != 1) print "ERR\t0\t現在の評価に「領域」の列の表がちょうど 1 つない"
      if (reviewcount != 1) print "ERR\t0\t「見直しの目安: <数> 日」の行がちょうど 1 行ない"
      else print "REVIEW\t" review
    }' "$TMP/script-names" "$QS" >"$TMP/qs"
else
  printf 'ERR\t0\t品質目標の文書が無い\n' >"$TMP/qs"
fi
REVIEW_DAYS="$(awk -F'\t' '$1 == "REVIEW" { print $2 }' "$TMP/qs")"
{
  echo "## 4 品質目標の評価"
  echo
  echo "見直しの目安: ${REVIEW_DAYS:-読めない} 日"
  echo
  echo "| 行の識別子 | 評価 | 評価した日からの日数 | 検査の結果 | 理由 | 印 |"
  echo "|---|---|---|---|---|---|"
} >"$TMP/sec4"
: >"$TMP/qs-err"
awk -F'\t' '$1 == "ERR" { print $2 "\t" $3 }' "$TMP/qs" >>"$TMP/qs-err"
stage_code() {
  awk -F'\t' -v s="$1" '$1 == s { print $2; exit }' "$TMP/stage-results"
}
while IFS="$SEP" read -r tag kind name rating idl d cm lineno extra; do
  [ "$tag" = "ROW" ] || continue
  # 分けた後に、各欄の形を確かめ直す（区切りがずれていたら読まない）
  if [ -n "$extra" ] || ! printf '%s' "$lineno" | grep -Eq '^[0-9]+$'; then
    printf '%s\t%s\n' "0" "現在の評価の表の行の欄を分けられない" >>"$TMP/qs-err"
    continue
  fi
  bad_field=0
  case "$kind" in 領域 | 層) ;; *) bad_field=1 ;; esac
  printf '%s' "$rating" | grep -Eq '^[ABCD]$' || bad_field=1
  printf '%s' "$idl" | grep -Eq '^([A-Za-z0-9:._-]+(,[A-Za-z0-9:._-]+)*)?$' || bad_field=1
  printf '%s' "$d" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || bad_field=1
  printf '%s' "$cm" | grep -Eq '^([0-9a-f]{7,40}|-)$' || bad_field=1
  if [ "$bad_field" = 1 ]; then
    printf '%s\t%s\n' "$lineno" "現在の評価の表の行の欄の形が違う" >>"$TMP/qs-err"
    continue
  fi
  if ! safe_name "$name"; then
    printf '%s\t%s\n' "$lineno" "現在の評価の表の名前のセルに使えない文字があるか、長すぎる" >>"$TMP/qs-err"
    continue
  fi
  days="$(days_since "$d")"
  if [ -z "$days" ]; then
    printf '%s\t%s\n' "$lineno" "現在の評価の表の評価した日が暦に無い" >>"$TMP/qs-err"
    continue
  fi
  results=""
  compared=0
  failed=0
  rest="$idl"
  while [ -n "$rest" ]; do
    id="${rest%%,*}"
    if [ "$id" = "$rest" ]; then rest=""; else rest="${rest#*,}"; fi
    code="$(stage_code "$id")"
    if [ -z "$code" ]; then
      r="照合しない"
    elif [ "$code" = 0 ]; then
      r="成功"
      compared=1
    else
      r="失敗"
      compared=1
      failed=1
    fi
    results="${results:+$results, }$id=$r"
  done
  [ -n "$results" ] || results="-"
  reasons=""
  if [ -n "$REVIEW_DAYS" ] && [ "$days" -gt "$REVIEW_DAYS" ]; then reasons="見直しの目安を超えた"; fi
  case "$rating" in
    A | B) [ "$failed" = 1 ] && reasons="${reasons:+${reasons}。}評価が $rating なのに識別子の段が失敗した" ;;
  esac
  if [ -n "$reasons" ]; then
    m="要対応"
    ATTN=$((ATTN + 1))
  elif [ "$compared" = 0 ]; then
    m="照合しない"
  else
    m="参考"
  fi
  echo "| \`4/$kind:$name\` | $rating | $days | $results | ${reasons:--} | $m |" >>"$TMP/sec4"
done <"$TMP/qs"
if [ -s "$TMP/qs-err" ]; then
  ATTN=$((ATTN + 1))
  why="$(sort -n "$TMP/qs-err" | awk -F'\t' '{ printf "%s%s%s", (NR > 1 ? "。" : ""), ($1 == 0 ? "" : $1 " 行: "), $2 }')"
  echo "| \`4/表\` | - | - | - | 品質目標の表を読めない（${why}） | 要対応 |" >>"$TMP/sec4"
fi

# --- 項目 5 実行の情報
REMOTE_ATTN=0
[ "$REMOTE_DAYS" -ge "$STALE_REMOTE_DAYS" ] && REMOTE_ATTN=1
OVERRIDE_ATTN=0
[ "$TEST_OVERRIDE" = "あり" ] && OVERRIDE_ATTN=1
m_remote="参考"
if [ "$REMOTE_ATTN" = 1 ]; then
  m_remote="要対応"
  ATTN=$((ATTN + 1))
fi
m_override="参考"
if [ "$OVERRIDE_ATTN" = 1 ]; then
  m_override="要対応"
  ATTN=$((ATTN + 1))
fi
{
  echo "## 5 実行の情報"
  echo
  echo "| 行の識別子 | 値 | 印 |"
  echo "|---|---|---|"
  echo "| \`5/契機\` | $TRIGGER | 参考 |"
  echo "| \`5/日時\` | $NOW | 参考 |"
  echo "| \`5/対象のコミット\` | $TARGET | 参考 |"
  echo "| \`5/間隔\` | $INTERVAL 日 | 参考 |"
  echo "| \`5/保存期間\` | $RETENTION | 参考 |"
  echo "| \`5/origin-既定のブランチ\` | 最後のコミットから $REMOTE_DAYS 日（$REMOTE_DATE${FETCH_NOTE}） | $m_remote |"
  echo "| \`5/試験の差し替え\` | $TEST_OVERRIDE | $m_override |"
} >"$TMP/sec5"

# --- 報告を書く（一時ディレクトリに書き、公開してよいかの検査を通ったときだけ --out へ移す）
mkdir -p -- "$TMP/out"
REPORT="$TMP/out/report.md"
{
  echo "走査の結果: 要対応 $ATTN 件"
  echo
  cat "$TMP/sec5"
  echo
  cat "$TMP/sec1"
  echo
  cat "$TMP/sec2"
  echo
  cat "$TMP/sec3"
  echo
  cat "$TMP/sec4"
  echo
  sed "s/@STALE_REMOTE_DAYS@/$STALE_REMOTE_DAYS/g" <<'EOF'
## この報告の書式

- 定期の走査（`scripts/harness/drift-scan.sh`）が作った報告である。1 行めは、印が「要対応」の行の数。
- 各行の 1 列めは行の識別子で、`<項目の番号>/<対象>` の形。項目は、1 検査の一式（`scripts/harness/stack-adapter.sh` が出す段）、2 文書の鮮度
  （`AGENTS.md` の文書の地図のファイル）、3 技術的負債の一覧（`3/<TD-n>`、表の書式の `3/表`、表に行が無いときの `3/なし`）、
  4 品質目標の評価（`4/領域:<領域>`、`4/層:<層>`、表の書式の `4/表`）、5 実行の情報。対象の名前のバッククォートは外してある。
- 印は、「要対応」（走査の決まりで対応が要ると判定した行）、「参考」（判定の材料）、「照合しない」のどれか。「照合しない」は、
  識別子が検査の一式の段に無いか識別子が無いため、段の結果と照らさなかった行で、評価した日からの日数の判定は済んでいる
  （見直しの目安を超えていれば要対応になる）。印は走査の機械的な判定で、実装と読み比べて確かめ直す。
- 値の意味: 「-」は、値が無いか数えなかったこと。「未コミット」は、文書がまだコミットされていないこと。「日付を読めない」は、
  見つけた日が YYYY-MM-DD の形の暦にある日付でないこと（`3/表` にも理由を書く）。「無い（場所を読めない）」は、場所が
  バッククォートで囲んだパスでないか、報告に書けない文字を含むこと（パスは書かない）。「無い（リポジトリの外を指す）」は、
  場所が `..` を含むか `/` で始まること。
- 要対応にする条件: 1 は終了コードが 0 でない段。3 は場所のファイルが無い行と、表を読めないとき（3/表）。4 は評価した日から
  見直しの目安の日数を超えた行と、評価が A か B なのに識別子の段のどれかが失敗した行、表を読めないとき（4/表）。5 は
  origin の既定のブランチの最後のコミットから @STALE_REMOTE_DAYS@ 日以上（公開リポジトリの予定実行は、60 日活動が無いと止まる）と、
  試験の差し替えが「あり」。2 は要対応にしない。
- 書くのは、識別子、リポジトリの根からの相対のパス、日付、日数、数、終了コード、印だけ。検査の出力は書かない。失敗した段の
  中身は、依頼元が同じコマンドを実行して得る。依頼文に無ければ、点検できなかった範囲とする。
- 契機が local の報告は、CI の外で作ったもので、日時と契機は予定実行のものではない。
EOF
} >"$REPORT"

# --- 公開してよいかの検査
publish_fail=""
add_fail() { publish_fail="${publish_fail}  - $1"$'\n'; }
others="$(ls -A "$TMP/out" | grep -vx 'report.md' || true)"
[ -z "$others" ] || add_fail "置き場に report.md 以外のファイルがある"
[ -f "$REPORT" ] && [ ! -L "$REPORT" ] || add_fail "report.md が普通のファイルではない"
grep -Eq '(^|[^A-Za-z0-9._-])/(home|Users|tmp|private|var|opt|runner)/' "$REPORT" && add_fail "絶対パスの形"
for v in "${GITHUB_WORKSPACE:-}" "${RUNNER_TEMP:-}"; do
  if [ -n "$v" ] && grep -qF -- "$v" "$REPORT"; then add_fail "CI の作業ディレクトリか一時ディレクトリのパス"; fi
done
grep -Eq '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}' "$REPORT" && add_fail "メールアドレスの形"
# 表の各セル（行の識別子は、項目の番号と「領域:」「層:」を除いた対象）が / か ~ で始まらないこと
if awk -F'|' '/^\|/ {
    for (i = 2; i < NF; i++) {
      v = $i; gsub(/^[ \t]+|[ \t]+$/, "", v); gsub(/`/, "", v); sub(/^[0-9]\/(領域:|層:)?/, "", v)
      if (v ~ /^(\/|~)/) bad = 1
    }
  } END { exit bad ? 0 : 1 }' "$REPORT"; then
  add_fail "表の値が / か ~ で始まる"
fi
# 秘匿値の確かめは、部品の秘匿値の検査に報告のファイルだけを渡す（0 = 無し、1 = 有り、ほかは道具が動かなかった）。
# 道具が動かなかったときは、確かめていない報告を公開しないよう、報告を消して終了コード 2 で止める
sl_rc=0
bash "$SECRETS" --file "$REPORT" </dev/null >/dev/null 2>&1 || sl_rc=$?
case "$sl_rc" in
  0) ;;
  1) add_fail "秘匿値の検査の規則に当たる値" ;;
  *) rm -f -- "$REPORT"
     die "秘匿値の検査が動きませんでした（終了コード ${sl_rc}）。報告を確かめられないので、報告を消しました" ;;
esac
if [ -n "$publish_fail" ]; then
  rm -f -- "$REPORT"
  printf 'drift-scan: 報告が公開してよいかの検査に通らないので、報告を消しました。当たった形:\n%s' "$publish_fail" >&2
  exit 3
fi

# 検査を通った報告を --out へ移す。走査の間に置き場へ何かが置かれていたら、混ぜずに止める
if [ -e "$OUT" ] || [ -L "$OUT" ]; then
  [ -d "$OUT" ] && [ ! -L "$OUT" ] || die "--out の置き場がディレクトリではなくなりました"
  [ -z "$(ls -A "$OUT")" ] || die "走査の間に、--out の置き場が空ではなくなりました"
fi
mkdir -p -- "$OUT"
mv -- "$REPORT" "$OUT/report.md"
[ "$(ls -A "$OUT")" = "report.md" ] || die "--out の置き場に report.md 以外のファイルがあります"
echo "drift-scan: 報告を書きました（要対応 $ATTN 件）"
