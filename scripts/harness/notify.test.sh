#!/usr/bin/env bash
# harness-copy: source=home/agents/skills/project-harness-init/assets/harness/notify.test.sh
# harness-copy: version=rules-2026.11.10-1
# harness-copy: sha256=0044d0e1727dad380a6109e31ba05bd5b474c5facd9ad8504b8c9f0a02b6807e
# harness-copy: この 4 行と本体は手で変えない。正本を直して project-harness-init の「導入済みのプロジェクトの更新」で置き換える
# 早期通知（notify.sh）と、check-docs.sh の --root、フックの設定（.claude/settings.json、.codex/hooks.json）と起動の部品
# （notify-launch.sh）の試験。試験 12 は、ひな形の設定のコマンドを /bin/sh -c で流し、起動の前の確かめの振る舞いを見る。
# ハーネスの検査の本体の写しで、どのプロジェクトでも同じ中身を置く。手元と CI で同じ形で呼ぶ:
#   bash scripts/harness/notify.test.sh
#
# 一時ディレクトリに、本体と worktree を持つ見本のリポジトリを作り、このファイルの置き場の notify.sh と check-docs.sh の
# 写しを置いて、フックの入力の見本を標準入力に渡して動かす。Claude Code と Codex は起動しない。見本の文書は、このファイルの
# 中で作り、リポジトリには置かない（文書の検査が見本を拾うため）。検査の呼び出しには、基準の日（HARNESS_TODAY）を決まった
# 日にして渡す（検査 11 の古い計画が基準の日を見るため）。
# /bin/bash（macOS では 3.2）で動く書き方だけを使う。
set -euo pipefail
export LC_ALL=C
unset HARNESS_NOTIFY HARNESS_NOTIFY_LOG HARNESS_NOTIFY_TIME_LIMIT GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
unset GITHUB_BASE_REF HARNESS_BASE_REF

H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$H/../.." && pwd -P)"

TMP_ROOT="$(mktemp -d)"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

TODAY="2026-01-15"
STDIN_FILE="$TMP_ROOT/stdin"
LOG="$TMP_ROOT/log"
ERR="$TMP_ROOT/err"
OUT=""
RC=0
EXTRA_ENV=()
passed=0
failed=0

FAIL_TEXT="が不合格です"
MAP_TEXT="文書の地図のパス docs/missing.md がありません"
SHAPE_TEXT="フックの入力の形が、想定と違います"
FOOTER_TEXT="これは早期通知で、作業は止めていません。止めるのは文書の検査のコマンドと CI です。"

# --- 見本を作る道具 ---

# 利用者の git の設定（署名、フック、既定のブランチの名前）に左右されない git
tgit() {
  git -c user.name=test -c user.email=test -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    -c init.defaultBranch=main -c core.fsmonitor=false "$@"
}

# 文書の検査を通る最小のファイルを置く（コミットはしない）。計画の書式の文書は、日数の行と必須の節の一覧だけの最小の形
write_base_files() {
  local d="$1"
  mkdir -p "$d/docs/exec-plans/active" "$d/docs/exec-plans/completed" "$d/scripts/harness"
  printf '%s\n' "# 試験" "" "ハーネスの版: 1" "" "## 検査のコマンド" "" "| 何を確かめるか | コマンド |" "|---|---|" \
    '| 文書（試験） | `bash scripts/harness/check-docs.sh` |' "" \
    "## 文書の地図" "" "| 種類 | パス |" "|---|---|" '| 計画の書式 | `docs/PLANS.md` |' '| 検査 | `scripts/harness/` |' > "$d/AGENTS.md"
  printf '%s\n' "# 計画" "" "## 必須の節" "" '1. `## 目的`: 何を行うか' "" "古い計画の日数: 30" "" "新しい書式の適用開始: 2099-01-01" > "$d/docs/PLANS.md"
  printf '@AGENTS.md\n' > "$d/CLAUDE.md"
  printf '%s\n' "format=1" "required.1=AGENTS.md" "required.1=docs/PLANS.md" "default_branch=main" > "$d/scripts/harness/harness.conf"
  : > "$d/docs/exec-plans/active/.gitkeep"
  : > "$d/docs/exec-plans/completed/.gitkeep"
}

commit_all() {
  tgit -C "$1" init -q
  tgit -C "$1" add -A
  tgit -C "$1" commit -q -m "見本"
}

# 文書の検査を通る見本のリポジトリ（本体）を作る。2 つのスクリプトは、このファイルの置き場の写し
make_repo() {
  write_base_files "$1"
  cp "$H/check-docs.sh" "$H/notify.sh" "$1/scripts/harness/"
  commit_all "$1"
}

add_worktree() {
  tgit -C "$1" worktree add -q --detach "$2" HEAD
}

# 作業ツリー $1 の文書の検査を不合格にする（地図に、実在しないパスの行を足す）
break_docs() {
  printf '| 無い文書 | `docs/missing.md` |\n' >> "$1/AGENTS.md"
}

# 起動元 $1 の check-docs.sh を、呼ばれた回数を $2 に書き足してから本物を動かす版に替える
install_counter() {
  mv "$1/scripts/harness/check-docs.sh" "$1/scripts/harness/check-docs.real.sh"
  {
    printf '#!/bin/bash\n'
    printf 'printf "%%s\\n" "$2" >> %q\n' "$2"
    printf 'exec /bin/bash %q "$@"\n' "$1/scripts/harness/check-docs.real.sh"
  } > "$1/scripts/harness/check-docs.sh"
}

claude_input() { # <書いたファイルのパス> <cwd>
  perl -MJSON::PP -e 'print JSON::PP->new->canonical->encode({ hook_event_name => "PostToolUse", tool_name => "Write",
    cwd => $ARGV[1], tool_input => { file_path => $ARGV[0], content => "x" } })' "$1" "$2"
}
codex_input() { # <cwd> <パッチの見出しの行>...
  local cwd="$1"
  shift
  perl -MJSON::PP -e 'my $cwd = shift; my $p = join("\n", "*** Begin Patch", @ARGV, "*** End Patch") . "\n";
    print JSON::PP->new->canonical->encode({ hook_event_name => "PostToolUse", tool_name => "apply_patch",
      cwd => $cwd, tool_input => { command => $p } })' "$cwd" "$@"
}

# 早期通知を 1 回動かす。$1 = notify.sh、$2 = 呼び出し元、$3 = 作業ディレクトリ、$4 = 標準入力の文字列
run_notify() {
  : > "$LOG"
  printf '%s' "$4" > "$STDIN_FILE"
  set +e
  OUT="$(cd "$3" && env ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} HARNESS_TODAY="$TODAY" HARNESS_NOTIFY_LOG="$LOG" \
    /bin/bash "$1" "$2" < "$STDIN_FILE" 2> "$ERR")"
  RC=$?
  set -e
  EXTRA_ENV=()
}

run_check() { # <スクリプト> <作業ディレクトリ> [引数...]
  local script="$1" cwd="$2"
  shift 2
  set +e
  OUT="$(cd "$cwd" && HARNESS_TODAY="$TODAY" bash "$script" "$@" 2>&1)"
  RC=$?
  set -e
}

# OUT の JSON から、追加の文脈の文面を出す（形が違えば失敗する）
ctx() {
  printf '%s' "$OUT" | perl -MJSON::PP -e 'local $/; my $o = eval { JSON::PP->new->utf8->decode(<STDIN>) } or exit 1;
    exit 1 unless ($o->{hookSpecificOutput}{hookEventName} // "") eq "PostToolUse";
    my $t = $o->{hookSpecificOutput}{additionalContext}; utf8::encode($t); print $t' 2> /dev/null
}

silent() { [ "$RC" -eq 0 ] && [ -z "$OUT" ]; }
told() {
  local text want
  [ "$RC" -eq 0 ] || return 1
  text="$(ctx)" || return 1
  for want in "$@"; do grep -qF -- "$want" <<<"$text" || return 1; done
}
not_told() { local text; text="$(ctx)" || return 1; ! grep -qF -- "$1" <<<"$text"; }
log_has() { grep -qF -- "$1" "$LOG"; }
no_file() { [ ! -e "$1" ]; }
file_lines() { [ -f "$1" ] && [ "$(wc -l < "$1" | tr -d ' ')" -eq "$2" ]; }
rc_is() { [ "$RC" -eq "$1" ]; }
out_has() { grep -qF -- "$1" <<<"$OUT"; }

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
    [ -f "$LOG" ] && sed 's/^/    ログ: /' "$LOG" >&2
    [ -f "$ERR" ] && sed 's/^/    標準エラー: /' "$ERR" >&2
    failed=$((failed + 1))
  fi
}

# --- 試験 1: 不合格なら文面が出て、通るなら何も出ない ---
R="$TMP_ROOT/t1/main"
make_repo "$R"
N="$R/scripts/harness/notify.sh"
run_notify "$N" claude "$R" "$(claude_input "$R/docs/PLANS.md" "$R")"
expect "1: 通る状態では何も出ない（claude）" silent
expect "1: 通る状態のログの結果は pass" log_has "result=pass"
run_notify "$N" codex "$R" "$(codex_input "$R" "*** Update File: docs/PLANS.md")"
expect "1: 通る状態では何も出ない（codex、相対のパス）" silent
expect "1: codex の相対のパスも検査する" log_has "result=pass"
break_docs "$R"
run_notify "$N" claude "$R" "$(claude_input "$R/docs/PLANS.md" "$R")"
expect "1: 不合格の文面が、終了コード 0 で出る（claude）" told "$FAIL_TEXT" "$MAP_TEXT" "$FOOTER_TEXT" "作業ツリー「main」"
expect "1: 文面の検査のコマンドは、AGENTS.md の検査のコマンドの表から読む" told "bash scripts/harness/check-docs.sh"
expect "1: 不合格のログの結果は fail" log_has "result=fail"
run_notify "$N" codex "$R" "$(codex_input "$R" "*** Update File: docs/PLANS.md")"
expect "1: 不合格の文面が、終了コード 0 で出る（codex）" told "$FAIL_TEXT" "$MAP_TEXT"
expect "1: 文面に、根の絶対パスを出さない" not_told "$R"

# --- 試験 2: 文書でも検査を定めるファイルでもないものだけのときは、何も出ず、検査も動かさない ---
R="$TMP_ROOT/t2/main"
make_repo "$R"
break_docs "$R"
install_counter "$R" "$TMP_ROOT/t2/count"
N="$R/scripts/harness/notify.sh"
run_notify "$N" claude "$R" "$(claude_input "$R/src/a.ts" "$R")"
expect "2: 文書でないファイルでは何も出ない" silent
expect "2: 検査を動かさない" no_file "$TMP_ROOT/t2/count"
expect "2: ログに not-md の数を残す" log_has "not-md:1"
run_notify "$N" codex "$R" "$(codex_input "$R" "*** Add File: src/a.ts" "*** Delete File: docs/a.mdx")"
expect "2: codex の文書でないファイルでも何も出ない" silent
expect "2: codex でも検査を動かさない" no_file "$TMP_ROOT/t2/count"

# --- 試験 3: 検査を定めるファイル（地図の「検査」の行のパスの下）を書いたら、検査を動かす ---
run_notify "$N" claude "$R" "$(claude_input "$R/scripts/harness/x.sh" "$R")"
expect "3: 検査を定めるファイルの書き込みで、不合格を知らせる" told "$FAIL_TEXT" "$MAP_TEXT"
expect "3: 検査を 1 回動かす" file_lines "$TMP_ROOT/t2/count" 1
run_notify "$N" claude "$R" "$(claude_input "$R/other/scripts/harness-x.sh" "$R")"
expect "3: 検査のパスに当たらないファイルでは何も出ない" silent
expect "3: 当たらないファイルでは検査を動かさない" file_lines "$TMP_ROOT/t2/count" 1

# --- 試験 4: HARNESS_NOTIFY=off では何もしない ---
EXTRA_ENV=(HARNESS_NOTIFY=off)
run_notify "$N" claude "$R" "$(claude_input "$R/docs/PLANS.md" "$R")"
expect "4: HARNESS_NOTIFY=off では何も出ない" silent
expect "4: HARNESS_NOTIFY=off ではログも書かない" file_lines "$LOG" 0

# --- 試験 5: 呼び出し元の名前の誤りと、入力の形の変化 ---
run_notify "$N" other "$R" "$(claude_input "$R/docs/PLANS.md" "$R")"
expect "5: 呼び出し元の名前が違えば、実行できなかったと知らせる" told "呼び出し元の名前が claude でも codex でもありません"
run_notify "$N" claude "$R" "これは JSON ではない"
expect "5: JSON でない入力は、形の変化として知らせる" told "$SHAPE_TEXT" "not-json"
run_notify "$N" claude "$R" '{"tool_input":{}}'
expect "5: file_path が無い入力は、形の変化として知らせる" told "$SHAPE_TEXT" "no-file-path"
run_notify "$N" codex "$R" '{"tool_input":{"command":"no header"}}'
expect "5: 見出しの無いパッチは、形の変化として知らせる" told "$SHAPE_TEXT" "no-patch-header"
run_notify "$N" codex "$R" '{"tool_input":{"command":"*** Update File: a.md"}}'
expect "5: 相対のパスで cwd が無い入力は、形の変化として知らせる" told "$SHAPE_TEXT" "no-cwd"

# --- 試験 6: 大きすぎる入力は読まずに知らせる ---
perl -e 'print "{\"tool_input\":{\"file_path\":\"" . ("x" x 8388700) . "\"}}"' > "$TMP_ROOT/big"
: > "$LOG"
set +e
OUT="$(cd "$R" && HARNESS_TODAY="$TODAY" HARNESS_NOTIFY_LOG="$LOG" /bin/bash "$N" claude < "$TMP_ROOT/big" 2> "$ERR")"
RC=$?
set -e
expect "6: 大きすぎる入力は、調べていないと知らせる" told "フックの入力が大きすぎて"

# --- 試験 7: 別のリポジトリと、シンボリックリンクの文書は対象外 ---
O="$TMP_ROOT/t7/other"
make_repo "$O"
break_docs "$O"
R="$TMP_ROOT/t7/main"
make_repo "$R"
N="$R/scripts/harness/notify.sh"
run_notify "$N" claude "$R" "$(claude_input "$O/docs/PLANS.md" "$R")"
expect "7: 別のリポジトリの文書では何も出ない" silent
expect "7: ログに other-repo を残す" log_has "other-repo"
ln -s "$R/docs/PLANS.md" "$R/docs/link.md"
run_notify "$N" claude "$R" "$(claude_input "$R/docs/link.md" "$R")"
expect "7: シンボリックリンクの文書では何も出ない" silent
expect "7: ログに symlink を残す" log_has "symlink"
rm -f "$R/docs/link.md"

# --- 試験 8: worktree の文書は、起動元の検査で調べ、worktree のスクリプトを動かさない ---
W="$TMP_ROOT/t8/wt"
R="$TMP_ROOT/t8/main"
make_repo "$R"
add_worktree "$R" "$W"
N="$R/scripts/harness/notify.sh"
printf '#!/bin/bash\n: > %q\nexit 0\n' "$TMP_ROOT/t8/evil-ran" > "$W/scripts/harness/check-docs.sh"
mkdir -p "$W/scripts/harness/checks.d"
printf '#!/bin/bash\n# 検査の名前: 悪い\n: > %q\nexit 0\n' "$TMP_ROOT/t8/evil-check-ran" > "$W/scripts/harness/checks.d/evil.sh"
break_docs "$W"
run_notify "$N" claude "$R" "$(claude_input "$W/docs/PLANS.md" "$W")"
expect "8: worktree の不合格を知らせる" told "$FAIL_TEXT" "作業ツリー「wt」"
expect "8: worktree の check-docs.sh を動かさない" no_file "$TMP_ROOT/t8/evil-ran"
expect "8: worktree の追加の検査を動かさない" no_file "$TMP_ROOT/t8/evil-check-ran"

# --- 試験 9: check-docs.sh の --root の誤りは、終了コード 2 ---
run_check "$R/scripts/harness/check-docs.sh" "$R" --root relative/path
expect "9: --root が相対のパスなら 2" rc_is 2
run_check "$R/scripts/harness/check-docs.sh" "$R" --root "$R/docs"
expect "9: --root が根でなければ 2" rc_is 2
run_check "$R/scripts/harness/check-docs.sh" "$R" --root "$W"
expect "9: --root で worktree を検査すると、不合格の 1" rc_is 1

# --- 試験 10: 本体は特定の言語の実行環境（JavaScript の実行環境）を呼ばず、ほかのファイルを読み込まない ---
no_runtime() { ! grep -nE '(^|[^A-Za-z_])no''de([^A-Za-z_]|$)' "$H/notify.sh" | grep -v '^[0-9]*:#' > /dev/null; }
no_source() { ! grep -nE '^[[:space:]]*(source|\.)[[:space:]]' "$H/notify.sh" > /dev/null; }
expect "10: notify.sh のコードが JavaScript の実行環境を呼ばない" no_runtime
expect "10: notify.sh はほかのファイルを読み込まない" no_source

# --- 試験 11: フックの設定（あるときだけ。どちらも、起動の部品 notify-launch.sh を HEAD から取り出して動かす形） ---
# 設定は JSON として読み、hooks.PostToolUse[].hooks[] のうち type が command のものの command だけを見る（引用符の
# 位置や空白の数、JSON の書き方の違いに左右されないため）。呼び出し元の名前の後ろは、空白、命令の区切り（; & | )）、
# 引用符、文字列の終わりのどれかで終わること（claudex のような別の名前を通さないため）。作業ツリーの notify.sh を
# 確かめずに直接呼ぶ前の形は、呼ぶと読まない（起動の前の確かめを通らないため）。
json_ok() { perl -MJSON::PP -e 'local $/; open(my $f, "<", $ARGV[0]) or exit 1; JSON::PP->new->decode(<$f>); exit 0' "$1" 2> /dev/null; }
# $1 の設定の、PostToolUse のフックの command を 1 つずつ出す（改行は空白に替える）。JSON として読めなければ失敗する
hook_commands() {
  perl -MJSON::PP -e 'local $/; open(my $f, "<", $ARGV[0]) or exit 1; my $o = eval { JSON::PP->new->utf8->decode(<$f>) };
    exit 1 unless ref $o eq "HASH"; my $p = ref $o->{hooks} eq "HASH" ? $o->{hooks}{PostToolUse} : undef;
    for my $g (ref $p eq "ARRAY" ? @$p : ()) { next unless ref $g eq "HASH" && ref $g->{hooks} eq "ARRAY";
      for my $h (@{$g->{hooks}}) { next unless ref $h eq "HASH" && ($h->{type} // "") eq "command" && defined $h->{command} && !ref $h->{command};
        my $c = $h->{command}; $c =~ s{[\r\n]+}{ }g; utf8::encode($c); print "$c\n" } }' "$1" 2> /dev/null
}
# $1 の設定の PostToolUse のフックのどれかが、$2 の正規表現（perl の書き方）に合う command を持つか
hook_has() {
  local cmds
  cmds="$(hook_commands "$1")" || return 1
  printf '%s\n' "$cmds" | perl -e 'my $re = shift; while (<STDIN>) { exit 0 if /$re/ } exit 1' "$2"
}
NOTIFY_END='(\s|[;&|)"'"'"']|$)'
LAUNCH_RE='ls-tree\s+HEAD\s+--\s+scripts/harness/notify-launch\.sh\b.*\bcat-file\s+blob\b.*\bnotify-launch-hook\s+'
calls_claude() { hook_has "$1" "$LAUNCH_RE"'claude'"$NOTIFY_END"; }
calls_codex() { hook_has "$1" "$LAUNCH_RE"'codex'"$NOTIFY_END"; }
reads_launch_from_head() { hook_has "$1" 'ls-tree\s+HEAD\s+--\s+scripts/harness/notify-launch\.sh\b.*\bcat-file\s+blob\b'; }
not() { ! "$@"; }

# 判定の道具そのものの試験。見本の設定は、規約の正本のひな形（敷くときに .claude/settings.json と .codex/hooks.json に
# なるもの）の今の中身と、形を変えたもの
S11="$TMP_ROOT/t11"
mkdir -p "$S11"
cat > "$S11/claude.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin ${HOME+\"HOME=$HOME\"} ${TMPDIR+\"TMPDIR=$TMPDIR\"} ${LANG+\"LANG=$LANG\"} ${HARNESS_NOTIFY+\"HARNESS_NOTIFY=$HARNESS_NOTIFY\"} ${HARNESS_NOTIFY_LOG+\"HARNESS_NOTIFY_LOG=$HARNESS_NOTIFY_LOG\"} ${CLAUDE_PROJECT_DIR+\"CLAUDE_PROJECT_DIR=$CLAUDE_PROJECT_DIR\"} GIT_NO_REPLACE_OBJECTS=1 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null /bin/bash -c '[ \"${HARNESS_NOTIFY:-}\" = off ] && exit 0; t0=$(date +%s); f() { printf \"%s\\n\" \"{\\\"hookSpecificOutput\\\":{\\\"hookEventName\\\":\\\"PostToolUse\\\",\\\"additionalContext\\\":\\\"早期通知は動きませんでした（起動の前の確かめが成り立ちません: $1）。作業は止めていません。\\\"}}\"; exit 0; }; g() { git --no-pager -c core.fsmonitor=false \"$@\" < /dev/null 2> /dev/null; }; r=$(g -C \"$CLAUDE_PROJECT_DIR\" rev-parse --show-toplevel); [ -n \"$r\" ] || f \"根を決められない\"; [ $(( $(date +%s) - t0 )) -lt 17 ] || f \"時間切れ\"; t=$(g -C \"$r\" ls-tree HEAD -- scripts/harness/notify-launch.sh); case \"$t\" in \"100644 blob \"*|\"100755 blob \"*) ;; *) f \"HEAD の scripts/harness/notify-launch.sh が無いか、通常のファイルでない\" ;; esac; o=${t#* blob }; o=${o%%[[:space:]]*}; s=$(g -C \"$r\" cat-file blob \"$o\"); [ -n \"$s\" ] || f \"HEAD から scripts/harness/notify-launch.sh を取り出せない\"; exec /bin/bash -c \"$s\" notify-launch \"$1\" \"$r\" \"$t0\"' notify-launch-hook claude",
            "timeout": 20
          }
        ]
      }
    ]
  }
}
EOF
cat > "$S11/codex.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "apply_patch",
        "hooks": [
          {
            "type": "command",
            "command": "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin ${HOME+\"HOME=$HOME\"} ${TMPDIR+\"TMPDIR=$TMPDIR\"} ${LANG+\"LANG=$LANG\"} ${HARNESS_NOTIFY+\"HARNESS_NOTIFY=$HARNESS_NOTIFY\"} ${HARNESS_NOTIFY_LOG+\"HARNESS_NOTIFY_LOG=$HARNESS_NOTIFY_LOG\"} ${CLAUDE_PROJECT_DIR+\"CLAUDE_PROJECT_DIR=$CLAUDE_PROJECT_DIR\"} GIT_NO_REPLACE_OBJECTS=1 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null /bin/bash -c '[ \"${HARNESS_NOTIFY:-}\" = off ] && exit 0; t0=$(date +%s); f() { printf \"%s\\n\" \"{\\\"hookSpecificOutput\\\":{\\\"hookEventName\\\":\\\"PostToolUse\\\",\\\"additionalContext\\\":\\\"早期通知は動きませんでした（起動の前の確かめが成り立ちません: $1）。作業は止めていません。\\\"}}\"; exit 0; }; g() { git --no-pager -c core.fsmonitor=false \"$@\" < /dev/null 2> /dev/null; }; r=$(g worktree list --porcelain | sed -n \"1s/^worktree //p\"); [ -n \"$r\" ] || f \"根を決められない\"; [ $(( $(date +%s) - t0 )) -lt 17 ] || f \"時間切れ\"; t=$(g -C \"$r\" ls-tree HEAD -- scripts/harness/notify-launch.sh); case \"$t\" in \"100644 blob \"*|\"100755 blob \"*) ;; *) f \"HEAD の scripts/harness/notify-launch.sh が無いか、通常のファイルでない\" ;; esac; o=${t#* blob }; o=${o%%[[:space:]]*}; s=$(g -C \"$r\" cat-file blob \"$o\"); [ -n \"$s\" ] || f \"HEAD から scripts/harness/notify-launch.sh を取り出せない\"; exec /bin/bash -c \"$s\" notify-launch \"$1\" \"$r\" \"$t0\"' notify-launch-hook codex",
            "timeout": 20
          }
        ]
      }
    ]
  }
}
EOF
printf '%s\n' '{"hooks":{"PostToolUse":[{"matcher":"Edit|Write","hooks":[{"type":"command","command":"t=$(git ls-tree HEAD -- scripts/harness/notify-launch.sh); s=$(git cat-file blob x); /bin/bash -c $s notify-launch-hook claude"}]}]}}' > "$S11/claude-bare.json"
printf '%s\n' '{"hooks":{"PostToolUse":[{"matcher":"apply_patch","hooks":[{"type":"command","command":"t=$(git ls-tree HEAD -- scripts/harness/notify-launch.sh); s=$(git cat-file blob x); /bin/bash -c $s notify-launch-hook codex"}]}]}}' > "$S11/codex-bare.json"
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Edit|Write","hooks":[{"type":"command","command":"t=$(git ls-tree HEAD -- scripts/harness/notify-launch.sh); s=$(git cat-file blob x); /bin/bash -c $s notify-launch-hook claude"}]}]},' \
  '"note":"t=$(git ls-tree HEAD -- scripts/harness/notify-launch.sh); s=$(git cat-file blob x); /bin/bash -c $s notify-launch-hook codex"}' > "$S11/outside.json"
printf '%s\n' '{"hooks":{"PostToolUse":[{"matcher":"Edit|Write","hooks":[{"type":"other","command":"t=$(git ls-tree HEAD -- scripts/harness/notify-launch.sh); s=$(git cat-file blob x); /bin/bash -c $s notify-launch-hook claude"},{"type":"command","command":"t=$(git ls-tree HEAD -- scripts/harness/notify-launch.sh); s=$(git cat-file blob x); /bin/bash -c $s notify-launch-hook claudex"}]}]}}' > "$S11/other-name.json"
printf '%s\n' '{"hooks":{"PostToolUse":[{"matcher":"Edit|Write","hooks":[{"type":"command","command":"/bin/bash \"$CLAUDE_PROJECT_DIR/scripts/harness/notify.sh\" claude"}]}]}}' > "$S11/claude-old.json"
expect "11: 正本のひな形の Claude Code の設定は、HEAD の notify-launch.sh を claude で動かすと読める" calls_claude "$S11/claude.json"
expect "11: 正本のひな形の Codex の設定は、HEAD の notify-launch.sh を codex で動かすと読める" calls_codex "$S11/codex.json"
expect "11: 正本のひな形の Codex の設定は、起動の部品を HEAD から取り出すと読める" reads_launch_from_head "$S11/codex.json"
expect "11: 引用符の無い形でも、claude で動かすと読める" calls_claude "$S11/claude-bare.json"
expect "11: 引用符の無い形でも、codex で動かすと読める" calls_codex "$S11/codex-bare.json"
expect "11: PostToolUse の外の command では、claude で動かすと読まない" not calls_claude "$S11/outside.json"
expect "11: PostToolUse の外の文字列では、codex で動かすと読まない" not calls_codex "$S11/outside.json"
expect "11: PostToolUse の外の command では、起動の部品を HEAD から取り出すと読まない" not reads_launch_from_head "$S11/outside.json"
expect "11: type が command でないものと、claudex のような別の名前は数えない" not calls_claude "$S11/other-name.json"
expect "11: 作業ツリーの notify.sh を確かめずに直接呼ぶ前の形は、claude で動かすと読まない" not calls_claude "$S11/claude-old.json"
# 埋め込んだ見本が、正本のひな形と同じ中身か（正本の置き場で流したときだけ。敷いた先には、ひな形のファイルが無い）
if [ -f "$H/../claude-settings.json" ] && [ -f "$H/../codex-hooks.json" ]; then
  expect "11: 埋め込んだ Claude Code の見本が、正本のひな形 claude-settings.json と同じ" cmp -s "$S11/claude.json" "$H/../claude-settings.json"
  expect "11: 埋め込んだ Codex の見本が、正本のひな形 codex-hooks.json と同じ" cmp -s "$S11/codex.json" "$H/../codex-hooks.json"
fi
# 2 つのひな形の確かめの部分が同じか。command を「r=$(」までの前の部分、そこから最初の「)」までの根を決める部分、
# 残りの後の部分の 3 つに切り、前の部分どうしと、後の部分の末尾の「notify-launch-hook <呼び出し元>」の名前を同じ語に替えたものどうしを
# 比べる（違ってよいのは、根を決める部分と呼び出し元の名前だけ）
template_parts() { # <設定> <呼び出し元>
  hook_commands "$1" | head -n 1 | perl -e 'my $who = shift; my $line = <STDIN>; exit 1 unless defined $line;
    exit 1 unless $line =~ /^(.*?\br=\$\()([^)]*)(\).*)$/; my ($a, $c) = ($1, $3); $c =~ s/\bnotify-launch-hook \Q$who\E\z/notify-launch-hook CALLER/ or exit 1;
    print "$a\n$c\n"' "$2"
}
same_checks() {
  local a b
  a="$(template_parts "$S11/claude.json" claude)" && b="$(template_parts "$S11/codex.json" codex)" && [ -n "$a" ] && [ "$a" = "$b" ]
}
expect "11: 2 つのひな形は、根を決める部分と呼び出し元の名前のほかは同じ" same_checks

if [ -f "$ROOT/.claude/settings.json" ]; then
  expect "11: .claude/settings.json が JSON として読める" json_ok "$ROOT/.claude/settings.json"
  expect "11: .claude/settings.json が HEAD の notify-launch.sh を claude で動かす" calls_claude "$ROOT/.claude/settings.json"
else
  echo "skip: 11: .claude/settings.json が無い"
fi
if [ -f "$ROOT/.codex/hooks.json" ]; then
  expect "11: .codex/hooks.json が JSON として読める" json_ok "$ROOT/.codex/hooks.json"
  expect "11: .codex/hooks.json が HEAD の notify-launch.sh を codex で動かす" calls_codex "$ROOT/.codex/hooks.json"
  expect "11: .codex/hooks.json が起動の部品を HEAD から取り出す" reads_launch_from_head "$ROOT/.codex/hooks.json"
else
  echo "skip: 11: .codex/hooks.json が無い"
fi

# --- 試験 12: フックの設定のコマンドの振る舞い（起動の前の確かめ） ---
# 埋め込んだひな形（S11。正本のひな形と同じ中身）の command を、/bin/sh -c で流す。見本のリポジトリには、このファイルの
# 置き場の notify-launch.sh と check-docs.sh の写しと、呼ばれたら目印のファイル（リポジトリの外）に呼び出し元・環境・
# 標準入力を書く偽物の notify.sh を置いてコミットする。変更の無い場面だけ目印ができ、ほかの場面では目印ができず、止めた
# 確かめの種類を添えた固定の文面が出ることを確かめる。
STOP_TEXT="早期通知は動きませんでした（起動の前の確かめが成り立ちません"
CLAUDE_CMD="$(hook_commands "$S11/claude.json" | head -n 1)"
CODEX_CMD="$(hook_commands "$S11/codex.json" | head -n 1)"
FIXED_PATH="PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
HOOK_INPUT='{"tool_input":{"file_path":"x"}}'
S12="$TMP_ROOT/t12"
R=""
MARK=""

# 見本のリポジトリを $S12/<名前>/r に作る。目印のファイルは $S12/<名前>/ran。偽物の notify.sh は、目印のパスを自分の置き場
# （<根>/scripts/harness）の 3 つ上から決めるので、どの見本でも同じ中身になる。そのため、コミットした見本を 1 回だけ作り、
# 場面ごとに cp -Rp で写す（git の初期化とコミットを場面ごとに繰り返さず、所要時間を抑えるため）
fresh() {
  local base="$S12/.base/r"
  if [ ! -d "$base" ]; then
    write_base_files "$base"
    mkdir -p "$base/scripts/harness/checks.d"
    cp "$H/check-docs.sh" "$H/notify-launch.sh" "$base/scripts/harness/"
    printf '# 追加の検査の口\n' > "$base/scripts/harness/checks.d/README.md"
    {
      printf '#!/bin/bash\n'
      printf 'mark="$(cd "$(dirname "$0")/../../.." && pwd -P)/ran"\n'
      printf '{ printf "caller=%%s\\n" "$1"; env; printf "stdin="; cat; printf "\\n"; } > "$mark"\n'
    } > "$base/scripts/harness/notify.sh"
    commit_all "$base"
  fi
  R="$S12/$1/r"
  MARK="$S12/$1/ran"
  mkdir -p "$S12/$1"
  cp -Rp "$base" "$R"
}

# フックの設定のコマンドを 1 回流す。$1 = claude か codex、$2 = 作業ディレクトリ、$3 = CLAUDE_PROJECT_DIR の値（- なら渡さない）、
# $4 以降 = 足す環境変数（名前=値）
run_hook() {
  local which="$1" dir="$2" pd="$3" cmd
  shift 3
  if [ "$which" = claude ]; then cmd="$CLAUDE_CMD"; else cmd="$CODEX_CMD"; fi
  printf '%s' "$HOOK_INPUT" > "$STDIN_FILE"
  set +e
  if [ "$pd" = "-" ]; then
    OUT="$(cd "$dir" && env -u CLAUDE_PROJECT_DIR "$@" /bin/sh -c "$cmd" < "$STDIN_FILE" 2> "$ERR")"
  else
    OUT="$(cd "$dir" && env CLAUDE_PROJECT_DIR="$pd" "$@" /bin/sh -c "$cmd" < "$STDIN_FILE" 2> "$ERR")"
  fi
  RC=$?
  set -e
}
ran() { [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -f "$MARK" ]; }
mark_has() { grep -qx -- "$1" "$MARK"; }
mark_lacks() { ! grep -q -- "$1" "$MARK"; }
time_limit_ok() { grep -qE '^HARNESS_NOTIFY_TIME_LIMIT=([1-9]|1[0-7])$' "$MARK"; }
stopped() { no_file "$MARK" && told "$STOP_TEXT" "$1"; }

fresh ok
run_hook claude "$S12/ok" "$R" FOO=leak BASH_ENV="$S12/ok/bash-env"
expect "12: 変更の無い作業ツリーでは、Claude Code の設定が notify.sh を動かす" ran
expect "12: 呼び出し元の名前は claude" mark_has "caller=claude"
expect "12: フックの入力は、そのまま notify.sh の標準入力に届く" mark_has "stdin=$HOOK_INPUT"
expect "12: notify.sh の PATH は固定の値" mark_has "$FIXED_PATH"
expect "12: 一覧に無い環境変数は notify.sh に届かない" mark_lacks "FOO="
expect "12: BASH_ENV は notify.sh に届かない" mark_lacks "BASH_ENV="
expect "12: notify.sh に、残りの秒数（1〜17）を HARNESS_NOTIFY_TIME_LIMIT で渡す" time_limit_ok
expect "12: notify.sh に GIT_NO_REPLACE_OBJECTS=1 を渡す" mark_has "GIT_NO_REPLACE_OBJECTS=1"
rm -f "$MARK"
run_hook codex "$R" -
expect "12: 変更の無い作業ツリーでは、Codex の設定が notify.sh を動かす" ran
expect "12: 呼び出し元の名前は codex" mark_has "caller=codex"
rm -f "$MARK"
run_hook claude "$R/docs" "$R/docs"
expect "12: CLAUDE_PROJECT_DIR が作業ツリーの部分ディレクトリなら止める" stopped "根がプロジェクトの根と違う"
run_hook claude "$R" -
expect "12: CLAUDE_PROJECT_DIR が無ければ止める" stopped "根がプロジェクトの根と違う"
printf '# 書き換え\n' >> "$R/scripts/harness/notify.sh"
run_hook claude "$R" "$R" HARNESS_NOTIFY=off
expect "12: HARNESS_NOTIFY=off なら、確かめが成り立たなくても何も出さず、動かさない" sh -c '[ "$1" -eq 0 ] && [ -z "$2" ] && [ ! -e "$3" ]' _ "$RC" "$OUT" "$MARK"

fresh unstaged
printf '# 書き換え\n' >> "$R/scripts/harness/notify.sh"
run_hook claude "$R" "$R"
expect "12: notify.sh を作業ツリーで書き換えると止める（Claude Code）" stopped "HEAD と中身が違う"
run_hook codex "$R" -
expect "12: notify.sh を作業ツリーで書き換えると止める（Codex）" stopped "HEAD と中身が違う"
tgit -C "$R" add scripts/harness/notify.sh
run_hook claude "$R" "$R"
expect "12: 書き換えをステージしても止める" stopped "HEAD と中身が違う"

fresh checkdocs
printf '# 書き換え\n' >> "$R/scripts/harness/check-docs.sh"
run_hook claude "$R" "$R"
expect "12: check-docs.sh を書き換えると止める" stopped "HEAD と中身が違う"

fresh untracked
printf '#!/bin/bash\nexit 0\n' > "$R/scripts/harness/checks.d/extra.sh"
run_hook claude "$R" "$R"
expect "12: checks.d に未追跡のファイルがあると止める" stopped "HEAD に無いファイルがある"

fresh excluded
printf 'local.sh\n' >> "$R/.git/info/exclude"
printf '#!/bin/bash\nexit 0\n' > "$R/scripts/harness/local.sh"
run_hook claude "$R" "$R"
expect "12: .git/info/exclude で除外した未追跡のファイルがあっても止める" stopped "HEAD に無いファイルがある"

fresh missing
rm -f "$R/scripts/harness/checks.d/README.md"
run_hook claude "$R" "$R"
expect "12: HEAD にあるファイルを作業ツリーで消すと止める" stopped "HEAD にあるファイルが無い"

fresh assume
tgit -C "$R" update-index --assume-unchanged scripts/harness/notify.sh
printf '# 書き換え\n' >> "$R/scripts/harness/notify.sh"
run_hook claude "$R" "$R"
expect "12: assume-unchanged の印を付けて書き換えても止める" stopped "HEAD と中身が違う"

fresh skip
tgit -C "$R" update-index --skip-worktree scripts/harness/notify.sh
printf '# 書き換え\n' >> "$R/scripts/harness/notify.sh"
run_hook claude "$R" "$R"
expect "12: skip-worktree の印を付けて書き換えても止める" stopped "HEAD と中身が違う"

# clean のフィルターは、呼ばれたら目印を書き、HEAD の中身を出す（git diff なら変更が無いと見える）
fresh filter
printf 'scripts/harness/notify.sh filter=evil\n' >> "$R/.git/info/attributes"
printf '# 書き換え\n' >> "$R/scripts/harness/notify.sh"
FILTER_CMD="sh -c ': > $S12/filter/filter-ran; git cat-file blob HEAD:scripts/harness/notify.sh'"
run_hook claude "$R" "$R" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=filter.evil.clean GIT_CONFIG_VALUE_0="$FILTER_CMD"
expect "12: 属性と GIT_CONFIG_COUNT で clean のフィルターを設定して書き換えても止める" stopped "HEAD と中身が違う"
expect "12: そのフィルターは動かない" no_file "$S12/filter/filter-ran"
printf '[filter "evil"]\n\tclean = %s\n' "$FILTER_CMD" > "$S12/filter/global.gitconfig"
run_hook claude "$R" "$R" GIT_CONFIG_GLOBAL="$S12/filter/global.gitconfig"
expect "12: GIT_CONFIG_GLOBAL で clean のフィルターを設定して書き換えても止める" stopped "HEAD と中身が違う"
expect "12: GIT_CONFIG_GLOBAL のフィルターも動かない" no_file "$S12/filter/filter-ran"

# HEAD に notify.sh をリンクとして記録し、リンク先を書き換える
fresh link
mv "$R/scripts/harness/notify.sh" "$S12/link/outside-notify.sh"
ln -s "$S12/link/outside-notify.sh" "$R/scripts/harness/notify.sh"
tgit -C "$R" add scripts/harness/notify.sh
tgit -C "$R" commit -q -m "リンク"
printf '# 書き換え\n' >> "$S12/link/outside-notify.sh"
run_hook claude "$R" "$R"
expect "12: HEAD に notify.sh がリンクとして記録されていれば止める" stopped "リンクがある"

# checks.d を、同じ中身のディレクトリへのリンクにする
fresh dirlink
mv "$R/scripts/harness/checks.d" "$S12/dirlink/checks.d"
ln -s "$S12/dirlink/checks.d" "$R/scripts/harness/checks.d"
run_hook claude "$R" "$R"
expect "12: checks.d をディレクトリへのリンクにすると止める" stopped "リンクがある"

fresh bashenv
printf ': > %q\n' "$S12/bashenv/bash-env-ran" > "$S12/bashenv/bash-env"
run_hook claude "$R" "$R" BASH_ENV="$S12/bashenv/bash-env" ENV="$S12/bashenv/bash-env"
expect "12: BASH_ENV と ENV を指定しても、変更が無ければ notify.sh を動かす" ran
expect "12: BASH_ENV と ENV のファイルは読まれない" no_file "$S12/bashenv/bash-env-ran"

fresh func
run_hook claude "$R" "$R" "BASH_FUNC_git%%=() { : > $S12/func/func-ran; }"
expect "12: 環境の関数 BASH_FUNC_git%% があっても、変更が無ければ notify.sh を動かす" ran
expect "12: 環境の関数 git は呼ばれない" no_file "$S12/func/func-ran"

# 作業ツリーの notify-launch.sh を、確かめずに notify.sh を動かす中身に書き換える
fresh launch
{
  printf '#!/bin/bash\n: > %q\n' "$S12/launch/evil-launch-ran"
  printf 'exec /bin/bash %q "$1"\n' "$R/scripts/harness/notify.sh"
} > "$R/scripts/harness/notify-launch.sh"
run_hook claude "$R" "$R"
expect "12: 作業ツリーの notify-launch.sh を書き換えても、HEAD の中身で確かめて止める" stopped "HEAD と中身が違う"
expect "12: 書き換えた notify-launch.sh は動かない" no_file "$S12/launch/evil-launch-ran"

# git replace で HEAD の notify-launch.sh を差し替え、作業ツリーも差し替えた中身にする
fresh replace
printf '#!/bin/bash\n: > %q\n' "$S12/replace/evil-replace-ran" > "$S12/replace/evil.sh"
evil_blob="$(tgit -C "$R" hash-object -w "$S12/replace/evil.sh")"
orig_blob="$(tgit -C "$R" rev-parse HEAD:scripts/harness/notify-launch.sh)"
tgit -C "$R" replace "$orig_blob" "$evil_blob"
cp "$S12/replace/evil.sh" "$R/scripts/harness/notify-launch.sh"
run_hook claude "$R" "$R"
expect "12: git replace で差し替えた notify-launch.sh は使わず、HEAD の本来の中身で確かめて止める" stopped "HEAD と中身が違う"
expect "12: 差し替えた中身は動かない" no_file "$S12/replace/evil-replace-ran"

fresh nonotify
tgit -C "$R" rm -q scripts/harness/notify.sh
tgit -C "$R" commit -q -m "消した"
run_hook claude "$R" "$R"
expect "12: HEAD に notify.sh が無ければ止める" stopped "HEAD に notify.sh か check-docs.sh が無い"

fresh nolaunch
tgit -C "$R" rm -q scripts/harness/notify-launch.sh
tgit -C "$R" commit -q -m "消した"
cp "$H/notify-launch.sh" "$R/scripts/harness/notify-launch.sh"
run_hook claude "$R" "$R"
expect "12: HEAD に notify-launch.sh が無ければ、設定のコマンドが固定の文面を出す（作業ツリーの写しは動かさない）" stopped "HEAD の scripts/harness/notify-launch.sh が無いか、通常のファイルでない"
run_hook codex "$R" -
expect "12: Codex の設定でも同じ" stopped "HEAD の scripts/harness/notify-launch.sh が無いか、通常のファイルでない"

# 外側のシェルの [ と printf を、環境の関数で置き換えようとする（外側では命令を動かさないので、呼ばれない）
fresh outerfunc
run_hook claude "$R" "$R" "BASH_FUNC_[%%=() { : > $S12/outerfunc/bracket-ran; }" "BASH_FUNC_printf%%=() { : > $S12/outerfunc/printf-ran; }" \
  "BASH_FUNC_test%%=() { : > $S12/outerfunc/test-ran; }"
expect "12: 環境の関数 [・printf・test があっても、変更が無ければ notify.sh を動かす" ran
expect "12: 環境の関数 [ は呼ばれない" no_file "$S12/outerfunc/bracket-ran"
expect "12: 環境の関数 printf は呼ばれない" no_file "$S12/outerfunc/printf-ran"
expect "12: 環境の関数 test は呼ばれない" no_file "$S12/outerfunc/test-ran"
rm -f "$MARK"
printf '# 書き換え\n' >> "$R/scripts/harness/notify.sh"
run_hook codex "$R" - "BASH_FUNC_[%%=() { : > $S12/outerfunc/bracket-ran; }" "BASH_FUNC_printf%%=() { : > $S12/outerfunc/printf-ran; }"
expect "12: 環境の関数があっても、確かめが成り立たなければ止める（Codex）" stopped "HEAD と中身が違う"
expect "12: 止める場面でも、環境の関数 [ と printf は呼ばれない" sh -c '[ ! -e "$1" ] && [ ! -e "$2" ]' _ "$S12/outerfunc/bracket-ran" "$S12/outerfunc/printf-ran"

# HEAD に notify-launch.sh をリンクとして記録する（リンク先の文字列は、動けば目印を書く命令）
fresh launchlink
rm -f "$R/scripts/harness/notify-launch.sh"
ln -s ": > $S12/launchlink/link-text-ran" "$R/scripts/harness/notify-launch.sh"
tgit -C "$R" add scripts/harness/notify-launch.sh
tgit -C "$R" commit -q -m "リンク"
run_hook claude "$R" "$R"
expect "12: HEAD に notify-launch.sh がリンクとして記録されていれば、取り出さずに止める" stopped "HEAD の scripts/harness/notify-launch.sh が無いか、通常のファイルでない"
expect "12: リンク先の文字列は動かない" no_file "$S12/launchlink/link-text-ran"

# 時間: 起動の部品に、設定のコマンドの内側の開始の時刻を、実際より前の値で渡す（確かめに時間がかかった場面の代わり）
fresh slow
LAUNCH_BODY="$(cat "$R/scripts/harness/notify-launch.sh")"
run_launch() { # <開始の時刻>
  printf '%s' "$HOOK_INPUT" > "$STDIN_FILE"
  set +e
  OUT="$(env -i PATH=/usr/bin:/bin CLAUDE_PROJECT_DIR="$R" /bin/bash -c "$LAUNCH_BODY" notify-launch claude "$R" "$1" < "$STDIN_FILE" 2> "$ERR")"
  RC=$?
  set -e
}
run_launch "$(($(date +%s) - 6))"
limit_at_most() { local v; v="$(sed -n 's/^HARNESS_NOTIFY_TIME_LIMIT=//p' "$MARK")"; [ -n "$v" ] && [ "$v" -ge 1 ] && [ "$v" -le "$1" ]; }
expect "12: 開始から 6 秒たっていれば、notify.sh を動かす" ran
expect "12: notify.sh へ渡す残りの秒数は、17 から経過秒を引いた値（11 以下）" limit_at_most 11
rm -f "$MARK"
run_launch "$(($(date +%s) - 17))"
expect "12: 開始から 17 秒たっていれば、notify.sh を動かさずに時間切れと知らせる" stopped "時間切れ"
rm -f "$MARK"
run_launch "1234567890123456789012345"
expect "12: 開始の時刻に 20 桁を超える値を渡しても、notify.sh を動かす" ran
expect "12: そのとき渡す残りの秒数は 1〜17 に収まる" limit_at_most 17

# CLAUDE_PROJECT_DIR の値（根のディレクトリの名前）にシングルクォートと $( ) を含める。値は命令として動かず、根として扱われる
fresh quote
QDIR="$S12/quote/a'b\$(touch inj-mark)"
mv "$R" "$QDIR"
R="$QDIR"
run_hook claude "$S12/quote" "$R"
expect "12: 根の名前にシングルクォートと \$( ) があっても、その根の notify.sh を動かす" ran
expect "12: 根の名前の \$( ) は命令として動かない" sh -c '[ ! -e "$1/inj-mark" ] && [ ! -e "$2/inj-mark" ]' _ "$S12/quote" "$R"

echo "notify.test: 合格 $passed 件、不合格 $failed 件"
[ "$failed" -eq 0 ]
