#!/usr/bin/env bash
# harness-copy: source=home/agents/skills/project-harness-init/assets/harness/notify.test.sh
# harness-copy: version=rules-2026.11.08-1
# harness-copy: sha256=375114e5d4ffbfc75dce8f6243af9936ba797cbddab83f53454186f3e9f539d5
# harness-copy: この 4 行と本体は手で変えない。正本を直して project-harness-init の「導入済みのプロジェクトの更新」で置き換える
# 早期通知（notify.sh）と、check-docs.sh の --root、フックの設定（.claude/settings.json、.codex/hooks.json）の試験。
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

# --- 試験 11: フックの設定（あるときだけ。どちらも、起動元の notify.sh を呼ぶ形） ---
# 設定は JSON として読み、hooks.PostToolUse[].hooks[] のうち type が command のものの command だけを見る（引用符の
# 位置や空白の数、JSON の書き方の違いに左右されないため）。呼び出し元の名前の後ろは、空白、命令の区切り（; & | )）、
# 引用符、文字列の終わりのどれかで終わること（claudex のような別の名前を通さないため）。
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
calls_claude() { hook_has "$1" 'notify\.sh["'"'"']?\s+claude'"$NOTIFY_END"; }
calls_codex() { hook_has "$1" 'notify\.sh["'"'"']?\s+codex'"$NOTIFY_END"; }
checks_docs_path() { hook_has "$1" 'check-docs\.sh'; }
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
            "command": "/bin/bash \"$CLAUDE_PROJECT_DIR/scripts/harness/notify.sh\" claude",
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
            "command": "root=$(git -c core.fsmonitor=false worktree list --porcelain | sed -n '1s/^worktree //p'); h=scripts/harness; harness_notify_git() { git --no-pager -C \"$root\" -c core.fsmonitor=false \"$@\"; }; test -n \"$root\" && test \"$(harness_notify_git rev-parse --is-bare-repository)\" = false && harness_notify_git cat-file -e \"HEAD:$h/notify.sh\" && harness_notify_git cat-file -e \"HEAD:$h/check-docs.sh\" && harness_notify_git diff --no-ext-diff --no-textconv --quiet HEAD -- \"$h\" && test -z \"$(harness_notify_git ls-files --others --exclude-standard -- \"$h\")\" && test -f \"$root/$h/notify.sh\" && exec /bin/bash \"$root/$h/notify.sh\" codex; printf '%s\\n' '{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"早期通知は動きませんでした（起動の前の確かめが成り立ちません）。作業は止めていません。\"}}'",
            "timeout": 20
          }
        ]
      }
    ]
  }
}
EOF
printf '%s\n' '{"hooks":{"PostToolUse":[{"matcher":"Edit|Write","hooks":[{"type":"command","command":"/bin/bash scripts/harness/notify.sh claude"}]}]}}' > "$S11/claude-bare.json"
printf '%s\n' '{"hooks":{"PostToolUse":[{"matcher":"apply_patch","hooks":[{"type":"command","command":"/bin/bash scripts/harness/notify.sh codex"}]}]}}' > "$S11/codex-bare.json"
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Edit|Write","hooks":[{"type":"command","command":"/bin/bash scripts/harness/notify.sh claude; test -f scripts/harness/check-docs.sh"}]}]},' \
  '"note":"/bin/bash scripts/harness/notify.sh codex"}' > "$S11/outside.json"
printf '%s\n' '{"hooks":{"PostToolUse":[{"matcher":"Edit|Write","hooks":[{"type":"other","command":"/bin/bash scripts/harness/notify.sh claude"},{"type":"command","command":"/bin/bash scripts/harness/notify.sh claudex"}]}]}}' > "$S11/other-name.json"
expect "11: 正本のひな形の Claude Code の設定は、notify.sh claude を呼ぶと読める" calls_claude "$S11/claude.json"
expect "11: 正本のひな形の Codex の設定は、notify.sh codex を呼ぶと読める（名前の直後が ;）" calls_codex "$S11/codex.json"
expect "11: 正本のひな形の Codex の設定は、check-docs.sh の在りかを確かめると読める" checks_docs_path "$S11/codex.json"
expect "11: 引用符の無い形でも、notify.sh claude を呼ぶと読める" calls_claude "$S11/claude-bare.json"
expect "11: 引用符の無い形でも、notify.sh codex を呼ぶと読める" calls_codex "$S11/codex-bare.json"
expect "11: PostToolUse の外の command では、notify.sh claude を呼ぶと読まない" not calls_claude "$S11/outside.json"
expect "11: PostToolUse の外の文字列では、notify.sh codex を呼ぶと読まない" not calls_codex "$S11/outside.json"
expect "11: PostToolUse の外の command では、check-docs.sh を確かめると読まない" not checks_docs_path "$S11/outside.json"
expect "11: type が command でないものと、claudex のような別の名前は数えない" not calls_claude "$S11/other-name.json"

if [ -f "$ROOT/.claude/settings.json" ]; then
  expect "11: .claude/settings.json が JSON として読める" json_ok "$ROOT/.claude/settings.json"
  expect "11: .claude/settings.json が notify.sh claude を呼ぶ" calls_claude "$ROOT/.claude/settings.json"
else
  echo "skip: 11: .claude/settings.json が無い"
fi
if [ -f "$ROOT/.codex/hooks.json" ]; then
  expect "11: .codex/hooks.json が JSON として読める" json_ok "$ROOT/.codex/hooks.json"
  expect "11: .codex/hooks.json が notify.sh codex を呼ぶ" calls_codex "$ROOT/.codex/hooks.json"
  expect "11: .codex/hooks.json が起動の前に check-docs.sh の在りかを確かめる" checks_docs_path "$ROOT/.codex/hooks.json"
else
  echo "skip: 11: .codex/hooks.json が無い"
fi

echo "notify.test: 合格 $passed 件、不合格 $failed 件"
[ "$failed" -eq 0 ]
