#!/bin/bash
# harness-copy: source=home/agents/skills/project-harness-init/assets/harness/notify-launch.sh
# harness-copy: version=rules-2026.11.10-1
# harness-copy: sha256=aab4bb180208745aedc5ac97fa82dd02eb469c4d0f59cd4b22e70d7a58e85758
# harness-copy: この 4 行と本体は手で変えない。正本を直して project-harness-init の「導入済みのプロジェクトの更新」で置き換える
# 早期通知の起動の部品。フックの設定（.claude/settings.json と .codex/hooks.json）が、早期通知の本体（notify.sh）を動かす前に、
# scripts/harness/ の下が HEAD に記録された中身と同じかを確かめる。同じときだけ notify.sh を動かし、違うときは notify.sh を
# 動かさずに、止めた確かめの種類を添えた固定の文面を出す。どちらでも終了コードは 0（作業は止めない）。
# ハーネスの検査の本体の写しで、どのプロジェクトでも同じ中身を置く。
#
# 呼び方（フックの設定だけが呼ぶ。作業ツリーのこのファイルは実行しない）:
#   設定のコマンドは、外側では /usr/bin/env -i で環境を空にした /bin/bash -c の起動 1 つだけを行う（外側のシェルの test や
#   printf は、環境の BASH_FUNC_ で始まる変数から取り込んだ関数で置き換えられうるため、外側では命令を動かさない）。その
#   内側で、開始の時刻を控え、根を決め、HEAD に記録されたこのファイルのモードが通常のファイル（100644・100755）であることを
#   ls-tree で確かめ（リンクとして記録されていれば、リンク先の文字列が動いてしまうため）、その blob を git cat-file blob で
#   取り出して、次の形で動かす。
#     /bin/bash -c "<取り出した中身>" notify-launch <claude|codex> <根の絶対パス> <内側の開始の時刻（エポック秒）>
#   作業ツリーで書き換えても、確かめは HEAD の中身で動く（書き換えた写しは、下の確かめで HEAD と違うとして止まる）。
#   標準入力はフックの入力のままで、ここでは読まずに notify.sh へ渡す（このファイルの中の命令は、標準入力を /dev/null にする）。
#   フックを動かすシェルは、Claude Code では sh -c（公式文書 https://code.claude.com/docs/en/hooks の「exec form and shell
#   form」の節）。Codex は公式文書で確かめられていない。どちらでも、外側のシェルは環境変数の値の展開と /usr/bin/env の起動だけを行う。
#   限界: 外側のシェルが起動のときに環境から読むもの（たとえば SHELLOPTS=xtrace と PS4 に書いた命令の置き換えは、
#   /usr/bin/env より前に実行される）は、コマンドの書き方では防げないので防がない。フックを動かすプロセスの環境は、フックの
#   設定と同じく利用者の側が決めるものとして扱い、守る相手は作業ツリーの書き換えだけとする。Codex のシェルが bash 系でない
#   場合（zsh が読む ~/.zshenv など）も同じ扱いとする。
#
# 守ること（変えるときは、scripts/harness/notify.test.sh の 12 の試験も見る）:
#   - 根は設定のコマンドが決める。Claude Code は CLAUDE_PROJECT_DIR の作業ツリーの根（セッションを始めた作業ツリー）、
#     Codex は git worktree list の 1 行目（本体の作業ツリー）。ここでは、その根が bare でない作業ツリーの最上位であることと、
#     Claude Code では CLAUDE_PROJECT_DIR の実体と一致することを確かめる（部分ディレクトリから起動したときは止める）。
#   - 確かめ（どれか 1 つでも成り立たなければ止める）:
#       a. HEAD の scripts/harness の下の全項目（git ls-tree -r -t）が、通常のファイル（100644・100755）かディレクトリで、
#          リンク（120000）や gitlink を含まない。scripts と scripts/harness 自体もディレクトリ。notify.sh と check-docs.sh がある。
#       b. 作業ツリーの scripts と scripts/harness がリンクでないディレクトリで、その下のすべての項目（find。リンクを辿らない）が
#          リンクでない通常のファイルかディレクトリ。
#       c. 作業ツリーのファイルとディレクトリの一覧が、HEAD の一覧と同じ（除外の設定に当たる未追跡のファイルも数える。
#          .DS_Store や編集ソフトの一時ファイルでも止まる）。
#       d. 各ファイルの中身の git hash-object --no-filters の値が、HEAD の blob の値と同じ（属性のフィルターも、index の
#          assume-unchanged・skip-worktree の印も効かない）。
#   - 環境: 設定のコマンドが env -i で空にした環境から、決まった一覧だけを受け取る。notify.sh も、ここから同じ一覧だけを
#     渡して動かす。一覧は、HOME・TMPDIR・LANG（文書の検査が日本語の文面を扱うため）・HARNESS_NOTIFY・HARNESS_NOTIFY_LOG
#     （notify.sh の設定）・CLAUDE_PROJECT_DIR（上の根の確かめ）と、固定の PATH、git が HEAD の差し替え（git replace）と
#     システム・利用者の全体の設定を読まないための GIT_NO_REPLACE_OBJECTS=1・GIT_CONFIG_NOSYSTEM=1・GIT_CONFIG_GLOBAL=/dev/null。
#     文書の検査の分岐元の指定（HARNESS_BASE_REF）は渡さない（早期通知は、設定の既定のブランチと比べる）。
#   - 時間: 設定のコマンドの内側の開始の時刻から共通の期限（17 秒）を数え、根の確かめ・HEAD の一覧・作業ツリーの探索・中身の
#     比べの各段の前に残りを確かめる。notify.sh へは「17 から経過秒を引いた値」を HARNESS_NOTIFY_TIME_LIMIT で渡す（notify.sh の
#     上限 18 秒より 1 秒短いのは、秒の端数の切り捨てと外側の起動の分を見込むため。フックの設定の timeout の 20 秒を超えない）。
#     残りが 1 秒未満なら、notify.sh を動かさずに時間切れの文面を出す。開始の時刻が無いか正しくなければ、この部品の開始から数える。
#   - git の呼び出しには -c core.fsmonitor=false を付ける。
#
# 限界（防がないもの。SKILL.md の「フックの設定の違い」にも書く）: 確かめてから notify.sh を動かすまでの間の書き換え、HEAD に
# 書き換えをコミットした場合（文書の検査と CI が既定のブランチへの混入を止める）、.git の下（config・objects・info/alternates）と、git
# worktree で作った作業ツリーの根の .git ファイル（gitdir を指す 1 つのファイル）の書き換え、フックの設定そのものの書き換え。core.autocrlf や属性の eol・ident で作業ツリーの中身が HEAD と違う環境では、
# 正当な写しも止まる。
# 確かめてから動かすまでの間の書き換えは、notify.sh だけでなく、その後に動く check-docs.sh と checks.d の下のスクリプトも
# 同じく防がない。この間に書き換えられるのは、フックが動いている最中に作業ツリーへ書き込める別のプロセスがある場合で、その
# プロセスはすでに命令を動かせるので、この確かめの守る範囲の外として扱う。
# 時間: 各段の前に残りの時間を確かめるが、段の途中（find・hash-object・git の呼び出し、notify.sh が AGENTS.md を読む処理）は
# 打ち切らない。そのため、極端に大きな作業ツリーや、追跡外のファイルが非常に多い場合は、フックの上限の 20 秒を超えることが
# あり、そのとき Claude Code はフックの出力を捨てる（通知が出ないだけで、書き換えられた写しが動くことにはならない）。
#
# /bin/bash（macOS では 3.2）で動く書き方だけを使う。

caller="${1:-}"
root="${2:-}"
started="${3:-}"
TIME_LIMIT=17
KEEP_PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin
H=scripts/harness
NL='
'

[ "${HARNESS_NOTIFY:-}" = "off" ] && exit 0
export LC_ALL=C
unset CDPATH

# 止めた確かめの種類（パスを含まない、決まった短い文）を添えて、固定の文面を出して終わる
stop() {
  printf '%s\n' "{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"早期通知は動きませんでした（起動の前の確かめが成り立ちません: $1）。作業は止めていません。scripts/harness/ の下を HEAD に記録された中身と同じにすると（足したファイルを消す、書き換えを戻すかコミットする）、動きます。\"}}"
  exit 0
}

now() { date +%s 2> /dev/null; }
# 開始の時刻（設定のコマンドの内側が控えたもの）。無いか、数でないか、今より後か、1 時間より前なら、ここから数える
t_now="$(now)"
case "$t_now" in
  ""|*[!0-9]*) stop "時間を測れない" ;;
esac
# 受けるのは 10〜11 桁の数（先頭は 1〜9）だけ（桁の多すぎる値で、算術の桁あふれを起こさないため）
case "$started" in
  [1-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]|[1-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
  *) started="$t_now" ;;
esac
if [ "$started" -gt "$t_now" ] || [ $((t_now - started)) -gt 3600 ]; then started="$t_now"; fi
# 残りの秒数（期限から経過秒を引いた値）
left() { echo $((TIME_LIMIT - ($(now) - started))); }
# 残りが 1 秒未満なら止める
in_time() { [ "$(left)" -ge 1 ] || stop "時間切れ"; }

g() { git --no-pager -c core.fsmonitor=false -C "$rr" "$@" < /dev/null 2> /dev/null; }

# ディレクトリを、実体の絶対パスにする
real_dir() { (cd -P -- "$1" 2> /dev/null && pwd -P); }

in_time
case "$caller" in
  claude|codex) ;;
  *) stop "呼び出し元の名前が違う" ;;
esac
case "$root" in
  /*) ;;
  *) stop "根を決められない" ;;
esac
rr="$(real_dir "$root")"
[ -n "$rr" ] || stop "根を決められない"
[ "$(g rev-parse --is-bare-repository)" = false ] || stop "根を決められない"
top="$(g rev-parse --show-toplevel)"
[ -n "$top" ] && [ "$(real_dir "$top")" = "$rr" ] || stop "根を決められない"
if [ "$caller" = claude ]; then
  [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ "$(real_dir "$CLAUDE_PROJECT_DIR")" = "$rr" ] || stop "根がプロジェクトの根と違う"
fi
g rev-parse --verify -q 'HEAD^{tree}' > /dev/null || stop "HEAD が無い"
cd -P -- "$rr" 2> /dev/null || stop "根を決められない"

in_time
# a. HEAD の一覧（ディレクトリとファイル。改行で区切る）と、ファイルの blob の値の一覧（ファイルと同じ順）
head_dirs=""
head_files=""
head_blobs=""
while IFS= read -r -d '' ent; do
  meta="${ent%%	*}"
  p="${ent#*	}"
  mode="${meta%% *}"
  rest="${meta#* }"
  type="${rest%% *}"
  obj="${rest#* }"
  case "$p" in *"$NL"*) stop "名前に改行がある" ;; esac
  case "$mode $type" in
    "040000 tree")
      [ "$p" = scripts ] || head_dirs="$head_dirs$p$NL" ;;
    "100644 blob"|"100755 blob")
      head_files="$head_files$p$NL"
      head_blobs="$head_blobs$obj$NL" ;;
    "120000 "*) stop "リンクがある" ;;
    *) stop "通常でない項目がある" ;;
  esac
done < <(g ls-tree -r -t -z HEAD -- "$H")
case "$NL$head_dirs" in *"$NL$H$NL"*) ;; *) stop "HEAD に notify.sh か check-docs.sh が無い" ;; esac
case "$NL$head_files" in
  *"$NL$H/notify.sh$NL"*) ;;
  *) stop "HEAD に notify.sh か check-docs.sh が無い" ;;
esac
case "$NL$head_files" in
  *"$NL$H/check-docs.sh$NL"*) ;;
  *) stop "HEAD に notify.sh か check-docs.sh が無い" ;;
esac

in_time
# b. 作業ツリーの一覧（find はリンクを辿らない）
for d in scripts "$H"; do
  [ -L "$d" ] && stop "リンクがある"
  [ -d "$d" ] || stop "HEAD にあるファイルが無い"
done
wt_dirs=""
wt_files=""
while IFS= read -r -d '' p; do
  case "$p" in *"$NL"*) stop "名前に改行がある" ;; esac
  if [ -L "$p" ]; then
    stop "リンクがある"
  elif [ -d "$p" ]; then
    wt_dirs="$wt_dirs$p$NL"
  elif [ -f "$p" ]; then
    wt_files="$wt_files$p$NL"
  else
    stop "通常でない項目がある"
  fi
done < <(find "$H" -print0 < /dev/null 2> /dev/null)

# c. 一覧を比べる（並べ替えてから）
sorted() { printf '%s' "$1" | sort; }
hd="$(sorted "$head_dirs")"
wd="$(sorted "$wt_dirs")"
hf="$(sorted "$head_files")"
wf="$(sorted "$wt_files")"
if [ "$hd" != "$wd" ] || [ "$hf" != "$wf" ]; then
  extra="$(comm -13 <(printf '%s\n' "$hd" "$hf" | sort) <(printf '%s\n' "$wd" "$wf" | sort))"
  [ -n "$extra" ] && stop "HEAD に無いファイルがある"
  stop "HEAD にあるファイルが無い"
fi

in_time
# d. 中身を比べる（フィルターを通さない値）
wt_blobs="$(printf '%s' "$head_files" | git --no-pager -c core.fsmonitor=false -C "$rr" hash-object --no-filters --stdin-paths 2> /dev/null)" \
  || stop "HEAD と中身が違う"
[ "$wt_blobs$NL" = "$head_blobs" ] || stop "HEAD と中身が違う"

left="$(left)"
[ "$left" -ge 1 ] || stop "時間切れ"

exec /usr/bin/env -i PATH="$KEEP_PATH" ${HOME+"HOME=$HOME"} ${TMPDIR+"TMPDIR=$TMPDIR"} ${LANG+"LANG=$LANG"} \
  ${HARNESS_NOTIFY+"HARNESS_NOTIFY=$HARNESS_NOTIFY"} ${HARNESS_NOTIFY_LOG+"HARNESS_NOTIFY_LOG=$HARNESS_NOTIFY_LOG"} \
  ${CLAUDE_PROJECT_DIR+"CLAUDE_PROJECT_DIR=$CLAUDE_PROJECT_DIR"} HARNESS_NOTIFY_TIME_LIMIT="$left" \
  GIT_NO_REPLACE_OBJECTS=1 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
  /bin/bash "$rr/$H/notify.sh" "$caller"
