#!/bin/bash
# harness-copy: source=home/agents/skills/project-harness-init/assets/harness/notify.sh
# harness-copy: version=rules-2026.11.13-1
# harness-copy: sha256=65de6439fc93e2eb5c57419be08a6a367267da0e75add50482f8a1b9e9a70640
# harness-copy: この 4 行と本体は手で変えない。正本を直して project-harness-init の「導入済みのプロジェクトの更新」で置き換える
# 早期通知。Claude Code の Edit・Write と、Codex の apply_patch がファイルを書いた直後に、フックから呼ばれる
# （.claude/settings.json と .codex/hooks.json。どちらも、起動の部品 notify-launch.sh で scripts/harness/ の下が HEAD と
# 同じかを確かめてから、このファイルを動かす）。書いたファイルのある作業ツリーの文書の検査（check-docs.sh）を動かし、
# 不合格をエージェントに知らせる。知らせるだけで、作業は止めない（止めるのは文書の検査のコマンドと CI）。
# ハーネスの検査の本体の写しで、どのプロジェクトでも同じ中身を置く。
#
# 使い方: /bin/bash notify.sh <claude|codex> < フックの入力の JSON
#
# 用語: 「起動元」は、このスクリプトのある作業ツリー。「対象」は、書いたファイルのある作業ツリー。
#
# 安全の決まり（変えるときは、scripts/harness/notify.test.sh の安全の試験も見る）:
# - 実行するプログラムは、起動元のものだけにする。対象の scripts/harness/ の下のファイル、設定のプログラム、依存の
#   パッケージを、起動も読み込みもしない。対象は、検査される文書としてだけ読む。同じリポジトリの別のブランチが
#   書き換えたスクリプトを、利用者の権限で動かさないためである。そのため、lint・型・試験は動かさない。
# - 起動元の根は、このファイルの置き場から決める。呼ばれたときの作業ディレクトリには頼らない。
# - このファイルと check-docs.sh の 2 つは、ほかのファイルを読み込んで実行しない（check-docs.sh は、起動元の
#   scripts/harness/checks.d/ の追加の検査だけを実行する）。動かすのは、互いと、perl・git などのプログラムだけである。
# - git の呼び出しには -c core.fsmonitor=false を付ける。
#
# 流れ:
#  1. 環境変数 HARNESS_NOTIFY=off のときは、何もせずに終わる。
#  2. 入力の変換（このファイルの中の perl。JSON::PP で読む）で、書いたファイルの絶対パスの一覧を得る。
#  3. パスごとに、対象にするかを決める（判定の順は classify_path）。対象外は、ログに理由を残すだけで、知らせない。
#     名前が .md で終わらないパスは、起動元の AGENTS.md の文書の地図の、1 列目が「検査」か「検査（」で始まる行のパス
#     （検査を定めるファイル。末尾が / ならその下）に当たるものだけを残し（文字列の照合だけで、git は呼ばない）、ほかは
#     数だけを数えて捨てる（いくつあっても、知らせない）。
#  4. 対象の根ごとに 1 回だけ、起動元の check-docs.sh を --root <対象の根> で動かす。1 回の通知で検査する根は MAX_ROOTS まで。
#  5. 不合格・時間切れ・入力の形の変化・起動の失敗・上限の超過（入力の大きさが MAX_INPUT_BYTES を超える、判定するパスが
#     MAX_PATHS を超える、根が MAX_ROOTS を超える）のときだけ、標準出力へ JSON（hookSpecificOutput.additionalContext）を出す。
#     対象外だけのときと、検査がすべて通ったときは、何も出さない。文面に出す根は、ディレクトリの名前だけにする
#     （絶対パスには、アカウント名が入るため）。
#  6. 終了コードは、どの場合も 0。
#
# 時間の上限は、全体で TIME_LIMIT 秒（フックの設定の timeout の 20 秒より短くする。設定の側が先に働くと、知らせを返せない）。
# 入力の変換、パスの判定の中の git の呼び出し、検査のどれも、残りの秒数を上限にして動かす（run_limited）。
# 環境変数 HARNESS_NOTIFY_TIME_LIMIT（1〜18 の整数）で短くできる。起動の部品（notify-launch.sh）が、起動の前の確かめに使った
# 秒数を引いた残りを渡す。試験でも使う。
#
# 書き込み: リポジトリの中には何も書かない（一時ファイルは、mktemp の一時ディレクトリに置いて消す）。
# 環境変数 HARNESS_NOTIFY_LOG があるときだけ、そのファイルに 1 行を足す（確認用。普段は設定しない）。行の項目は、時刻、
# 呼び出し元（caller）、起動元の根（origin）、検査した根（checked）、対象にした文書（files）、対象外にしたパスの数と理由
# （skipped）、結果（result）で、タブで区切る。この行には絶対パスが入るので、公開する文書へ写すときは置き換える。
#
# /bin/bash（macOS では 3.2）で動く書き方だけを使う。

[ "${HARNESS_NOTIFY:-}" = "off" ] && exit 0

export LC_ALL=C
# 呼び出し元の環境の git の変数で、調べるリポジトリが変わらないようにする
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_PREFIX
# cd が、呼び出し元の環境の CDPATH で、別のディレクトリへ移らないようにする
unset CDPATH

TIME_LIMIT=18
MAX_ROOTS=3
# 1 回の通知で判定するパスの数の上限（多すぎる入力で、判定に時間を使い切らないため）。数えるのは、入力の変換が
# 出すパス（名前が .md で終わるものと、検査を定めるファイル、判定できないもの）で、捨てたパスは数えない
MAX_PATHS=200
# フックの入力の大きさの上限（8 MiB）。超える入力は、読むのをやめて、検査しない（メモリーと時間を使い切らないため）
MAX_INPUT_BYTES=8388608
MAX_CHARS=2000
TAIL_LINES=30
FOOTER='これは早期通知で、作業は止めていません。止めるのは文書の検査のコマンドと CI です。'
# 文面の中で案内する、文書の検査のコマンド（起動元の AGENTS.md の「## 検査のコマンド」の表から読み直す）
DOCS_CMD='bash scripts/harness/check-docs.sh'

# 受けるのは、先頭が 0 でない 1〜2 桁の整数だけ（08 や 09 は、算術の式で 8 進数の誤りになり、上限が働かなくなるため）
case "${HARNESS_NOTIFY_TIME_LIMIT:-}" in
  [1-9]|[1-9][0-9])
    if [ "$HARNESS_NOTIFY_TIME_LIMIT" -le "$TIME_LIMIT" ]; then
      TIME_LIMIT="$HARNESS_NOTIFY_TIME_LIMIT"
    fi
    ;;
esac

caller="${1:-}"
tmp=""
origin=""
origin_common=""
message=""
result=""
checked=""
files=""
skipped_reasons=""
not_md_count=0   # 入力の変換が、文書でも検査を定めるファイルでもないので捨てたパスの数

cleanup() {
  [ -n "$tmp" ] && rm -rf "$tmp"
  exit 0
}
trap cleanup EXIT

# ログの 1 行に入れる値から、タブと改行を除く
one_line() {
  local v="$1"
  v="${v//$'\t'/?}"
  v="${v//$'\n'/?}"
  printf '%s' "$v"
}

write_log() {
  [ -n "${HARNESS_NOTIFY_LOG:-}" ] || return 0
  local reason r n summary="" total=0
  # 理由ごとの数は、skipped_reasons に実際にある語から数える（理由の名前の一覧を、classify_path と二重に持たない）。
  # 入力の変換が捨てた数（not_md_count）は、classify_path の not-md と同じ理由として足す
  if [ "$not_md_count" -gt 0 ]; then
    n="$not_md_count"
    for r in $skipped_reasons; do
      [ "$r" = "not-md" ] && n=$((n + 1))
    done
    summary="not-md:$n"
    total="$n"
  fi
  for reason in $skipped_reasons; do
    case ",$summary" in
      *",$reason:"*) continue ;;
    esac
    n=0
    for r in $skipped_reasons; do
      [ "$r" = "$reason" ] && n=$((n + 1))
    done
    summary="${summary:+$summary,}$reason:$n"
    total=$((total + n))
  done
  printf '%s\tcaller=%s\torigin=%s\tchecked=%s\tfiles=%s\tskipped=%s(%s)\tresult=%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)" "$(one_line "$caller")" "$(one_line "$origin")" \
    "$(one_line "$checked")" "$(one_line "$files")" "$total" "$summary" "${result:-none}" \
    >> "$HARNESS_NOTIFY_LOG" 2>/dev/null
}

# perl で JSON を作れないときの、変数を含まない固定の文面
emit_fixed() {
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"早期通知を実行できませんでした（perl を起動できないか、文面を作れません）。これは早期通知で、作業は止めていません。止めるのは文書の検査のコマンドと CI です。"}}'
}

# 文面（$message）を、上限の字数に切って、JSON にして出す
emit_message() {
  [ -n "$message" ] || return 0
  if ! command -v perl > /dev/null 2>&1; then
    emit_fixed
    return 0
  fi
  printf '%s' "$message" | perl -MJSON::PP -e '
    my ($max, $footer) = @ARGV;
    utf8::decode($footer);
    my $cut = "（文面が長いので、ここで切りました）";
    utf8::decode($cut);
    local $/; my $body = <STDIN>; $body = "" unless defined $body;
    utf8::decode($body);
    $body =~ s/\s+\z//;
    my $room = $max - length($footer) - 1;
    if (length($body) > $room) { $body = substr($body, 0, $room - length($cut) - 1) . "\n" . $cut }
    my $out = { hookSpecificOutput => { hookEventName => "PostToolUse", additionalContext => $body . "\n" . $footer } };
    print JSON::PP->new->utf8->canonical->encode($out), "\n";
  ' "$MAX_CHARS" "$FOOTER" 2>/dev/null || emit_fixed
}

# 入力の変換。標準入力のフックの入力から、道具が書いたファイルのパスを取り出し、1 件ずつ NUL で終わる形で出す。
# 引数: <claude|codex> <出すパスの数の上限> <入力のバイト数の上限> <検査を定めるパスの並び（改行区切り）>
# - 出すのは絶対パス。相対パスは、入力の cwd の項目を基準に、文字列としてつなぐ（.. を畳まない。実体のパスへの解決は
#   classify_path が行う）。判定できないパスは、!empty・!control の目印を出す。
# - 名前が .md で終わるパスと、検査を定めるパス（末尾が / でなければ「/<パス>」で終わるもの、末尾が / なら「/<パス>」を
#   含むもの）だけを出す。ほかは数だけを最後に !not-md:<数> の 1 件で出す。出すパスが上限を超えたら、最後に !too-many。
# - claude: tool_input.file_path の 1 件。codex: tool_input.command（apply_patch のパッチの全文）の見出しの行
#   （*** Add File: 、*** Update File: 、*** Delete File: 、*** Move to: ）のパス。
# 終了コード: 0 = 取り出せた。3 = 入力の形が想定と違う（理由を標準エラーに 1 語で出す）。4 = 引数の誤り。5 = 大きすぎる。
PATHS_PL='
  use strict; use warnings; use JSON::PP;
  my ($caller, $max_records, $max_bytes, $checks) = @ARGV;
  sub shape { print STDERR "$_[0]\n"; exit 3 }
  if (($caller ne "claude" && $caller ne "codex") || $max_records !~ /^[1-9][0-9]*$/ || $max_bytes !~ /^[1-9][0-9]*$/) {
    print STDERR "bad-arguments\n"; exit 4;
  }
  my @check = grep { $_ ne "" } split /\n/, (defined $checks ? $checks : "");
  utf8::decode($_) for @check;
  binmode STDIN; binmode STDOUT;
  my ($text, $buf, $total) = ("", "", 0);
  while (1) {
    my $n = sysread(STDIN, $buf, 65536);
    shape("unreadable") unless defined $n;
    last if $n == 0;
    $total += $n;
    if ($total > $max_bytes) { print STDERR "too-large\n"; exit 5 }
    $text .= $buf;
  }
  shape("empty") if $text =~ /\A\s*\z/;
  my $in = eval { JSON::PP->new->utf8->decode($text) };
  shape("not-json") unless defined $in;
  shape("no-tool-input") unless ref($in) eq "HASH" && ref($in->{tool_input}) eq "HASH";
  my @paths;
  if ($caller eq "claude") {
    my $f = $in->{tool_input}{file_path};
    shape("no-file-path") unless defined $f && !ref($f);
    @paths = ($f);
  } else {
    my $p = $in->{tool_input}{command};
    shape("no-command") unless defined $p && !ref($p);
    for my $line (split /\n/, $p, -1) {
      $line =~ s/\r\z//;
      push @paths, $1 if $line =~ /^\*\*\* (?:Add File|Update File|Delete File|Move to): (.*)$/;
    }
    shape("no-patch-header") unless @paths;
  }
  my $cwd = $in->{cwd};
  my (%seen, @records);
  my ($not_md, $too_many) = (0, 0);
  for my $path (@paths) {
    my $rec;
    if ($path eq "") { $rec = "!empty" }
    elsif ($path =~ /[\0\n\r]/) { $rec = "!control" }
    elsif ($path =~ m{^/}) { $rec = $path }
    else {
      shape("no-cwd") unless defined $cwd && !ref($cwd) && $cwd =~ m{^/} && $cwd !~ /[\0\n\r]/;
      $rec = $cwd =~ m{/\z} ? "$cwd$path" : "$cwd/$path";
    }
    next if $seen{$rec}++;
    my $keep = 1;
    if ($rec =~ m{^/} && $rec !~ /\.md\z/) {
      $keep = 0;
      for my $c (@check) {
        if ($c =~ m{/\z}) { $keep = 1, last if index($rec, "/$c") >= 0 }
        else { $keep = 1, last if substr($rec, -length("/$c")) eq "/$c" }
      }
    }
    if (!$keep) { $not_md++ }
    elsif (@records >= $max_records) { $too_many = 1; last }
    else { push @records, $rec }
  }
  push @records, "!not-md:$not_md" if $not_md > 0;
  push @records, "!too-many" if $too_many;
  for my $r (@records) { utf8::encode($r) if utf8::is_utf8($r); print "$r\0" }
'

# 起動元の AGENTS.md の文書の地図の、1 列目が「検査」か「検査（」で始まる行の、2 列目のバッククォートの中のパスを出す
check_paths_of_origin() {
  [ -f "$origin/AGENTS.md" ] || return 0
  awk '/^## /{ on = ($0 == "## 文書の地図"); next } on' "$origin/AGENTS.md" | awk -F '|' '
    /^\|/ {
      k = $2; gsub(/^[ \t]+|[ \t]+$/, "", k)
      if (k != "検査" && index(k, "検査（") != 1) next
      v = $3
      while (match(v, /`[^`]+`/)) { print substr(v, RSTART + 1, RLENGTH - 2); v = substr(v, RSTART + RLENGTH) }
    }'
}

# 起動元の AGENTS.md の「## 検査のコマンド」の表の、1 列目が「文書（」で始まる行のコマンド（無ければ既定のまま）
read_docs_cmd() {
  local c=""
  [ -f "$origin/AGENTS.md" ] || return 0
  c="$(awk '/^## /{ on = ($0 == "## 検査のコマンド"); next } on && /^\| *文書（/' "$origin/AGENTS.md" | head -n 1 \
    | awk -F '|' '{ print $3 }' | sed -n 's/^[^`]*`\([^`]*\)`.*$/\1/p')"
  case "$c" in
    ''|*[!A-Za-z0-9\ ._/:=+-]*) ;;
    *) DOCS_CMD="$c" ;;
  esac
}

add_message() {
  message="${message:+$message
}$1"
}

add_result() {
  case ",$result," in
    *",$1,"*) ;;
    *) result="${result:+$result,}$1" ;;
  esac
}

finish() {
  emit_message
  write_log
  exit 0
}

launch_failed() {
  add_message "早期通知を実行できませんでした（$1）。文書の検査は動かしていません。"
  add_result launch-failed
  finish
}

# 残りの秒数（全体の上限から、ここまでにかかった秒数を引いたもの）
remaining() {
  echo $((TIME_LIMIT - SECONDS))
}

# コマンドを、秒数の上限つきで動かす。$1 = 秒数、$2 以降 = コマンド。コマンドは自分のプロセスグループで動かし、
# 時間が来たら、グループごと終了させて、終了コード 142 を返す（子のプロセスを残さないため）。
# 秒数が 1 以上の整数でないときは、動かさずに 142 を返す（上限の無い実行をしないため）
run_limited() {
  local seconds="$1"
  shift
  case "$seconds" in
    ''|*[!0-9]*|0*) return 142 ;;
  esac
  perl -e '
    $t = shift;
    $pid = fork;
    exit 127 unless defined $pid;
    if (!$pid) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV; exit 127 }
    $SIG{ALRM} = sub {
      kill "TERM", -$pid;
      select(undef, undef, undef, 0.3);
      kill "KILL", -$pid;
      waitpid($pid, 0);
      exit 142;
    };
    alarm $t;
    waitpid($pid, 0);
    $s = $?;
    alarm 0;
    exit(($s & 127) ? 128 + ($s & 127) : $s >> 8);
  ' "$seconds" "$@"
}

# ディレクトリを、実体の絶対パス（シンボリックリンクを辿った後のパス）にする
real_dir() {
  (cd -- "$1" 2>/dev/null && pwd -P)
}

# パスの判定の中の git。残りの秒数を上限にして動かす（最後の 1 件の git が長引いても、全体の上限を超えないため）。
# 時間切れのときは、終了コード 142 を返す
limited_git() {
  run_limited "$(remaining)" git --no-pager -c core.fsmonitor=false "$@"
}

# ディレクトリ（$1）から見つかる、git の共通のディレクトリを、実体の絶対パスで出す。時間切れのときは 142 を返す
common_dir_of() {
  local c rc
  c="$(limited_git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  rc=$?
  [ "$rc" -eq 142 ] && return 142
  [ "$rc" -eq 0 ] && [ -n "$c" ] || return 1
  real_dir "$c"
}

# git と、起動元の検査のスクリプトを確かめ、起動元の共通のディレクトリを求める（文書のパスが初めて来たときに 1 回だけ）。
# 時間切れのときは 142 を返す
prepare_origin() {
  [ -n "$origin_common" ] && return 0
  command -v git > /dev/null 2>&1 || launch_failed "git が見つかりません"
  [ -f "$origin/scripts/harness/check-docs.sh" ] || launch_failed "起動元に scripts/harness/check-docs.sh がありません"
  local top rc
  top="$(limited_git -C "$origin" rev-parse --show-toplevel 2>/dev/null)"
  rc=$?
  [ "$rc" -eq 142 ] && return 142
  [ "$rc" -eq 0 ] || top=""
  if [ -z "$top" ] || [ "$(real_dir "$top")" != "$origin" ]; then
    launch_failed "起動元が git の作業ツリーの根ではありません"
  fi
  origin_common="$(common_dir_of "$origin")"
  rc=$?
  if [ "$rc" -eq 142 ]; then
    origin_common=""
    return 142
  fi
  [ "$rc" -eq 0 ] && [ -n "$origin_common" ] || launch_failed "起動元の git のディレクトリを求められません"
}

# 親ディレクトリ（実体のパス。$1）のある作業ツリーの根を決める。対象なら、根を parent_root に入れて 0 を返す。対象外なら、
# 理由を parent_reason に入れて 1 を返す。時間切れのときは 142 を返す。直前と同じ親ディレクトリなら、前の結果を使う
# （同じディレクトリの文書を多く書いたときに、git を呼び直さないため）
cached_parent=""
parent_root=""
parent_reason=""
resolve_parent() {
  local real_parent="$1" top common rc
  [ -n "$cached_parent" ] && [ "$real_parent" = "$cached_parent" ] && { [ -n "$parent_root" ]; return; }
  cached_parent=""
  parent_root=""
  parent_reason=""
  prepare_origin || return 142
  top="$(limited_git -C "$real_parent" rev-parse --show-toplevel 2>/dev/null)"
  rc=$?
  [ "$rc" -eq 142 ] && return 142
  [ "$rc" -eq 0 ] || top=""
  [ -n "$top" ] && top="$(real_dir "$top")"
  if [ -z "$top" ]; then
    parent_reason=not-git
  else
    # 共通のディレクトリは、根からではなく、根を求めたのと同じ親ディレクトリから求める。追跡された中身に埋め込まれた
    # git のディレクトリが、設定で作業ツリーを同じリポジトリの worktree に向けていても、別のリポジトリと判定するためである。
    # 同じ理由で、親ディレクトリが、求めた根の下に無いものも対象外にする
    common="$(common_dir_of "$real_parent")"
    rc=$?
    [ "$rc" -eq 142 ] && return 142
    [ "$rc" -eq 0 ] || common=""
    if [ -z "$common" ] || [ "$common" != "$origin_common" ]; then
      parent_reason=other-repo
    else
      case "$real_parent/" in
        "$top"/*) parent_root="$top" ;;
        *) parent_reason=other-repo ;;
      esac
    fi
  fi
  cached_parent="$real_parent"
  [ -n "$parent_root" ]
}

# パスを 1 つ判定する。対象なら、対象の根を target_root に入れて 0 を返す。対象外なら、理由を skip_reason に入れて 1 を返す。
# 時間切れで判定できなかったときは 142 を返す。
# 判定の順（名前が .md で終わるかを見るまでは、git を呼ばない。文書でない書き込みで、余計なプロセスを起こさないため）:
#   1. 空のパス、NUL や改行を含むパス（入力の変換が「!」で始まる目印にする）は対象外
#   2. 名前が .md で終わらず、検査を定めるパス（is_check_path）にも当たらないものは対象外（入力の変換が先に捨てるので、
#      ここへは来ない。念のための判定）。検査を定めるパスは、文書と同じに判定し、その作業ツリーの文書の検査を動かす
#   3. 親ディレクトリを実体のパスにする（パスの中の「..」は拒否しない。安全は 4 と 5 の照合で守る）。親が無ければ対象外。
#      ファイルそのものがシンボリックリンクなら対象外
#   4. 親ディレクトリのある git の作業ツリーの根を求める。求められなければ対象外
#   5. 親ディレクトリから見つかる git の共通のディレクトリが、起動元のものと違えば（別のリポジトリ）対象外
classify_path() {
  local p="$1" parent base real_parent rc
  target_root=""
  skip_reason=""
  case "$p" in
    '!empty') skip_reason=empty; return 1 ;;
    '!'*) skip_reason=control; return 1 ;;
    /*) ;;
    *) skip_reason=not-absolute; return 1 ;;
  esac
  case "$p" in
    *.md) ;;
    *)
      # 検査を定めるファイルか（入力の変換が残したもの。地図の検査の行で確かめ直す）
      is_check_path "$p" || { skip_reason=not-md; return 1; } ;;
  esac
  base="${p##*/}"
  parent="${p%/*}"
  [ -n "$parent" ] || parent=/
  real_parent="$(real_dir "$parent")"
  if [ -z "$real_parent" ]; then
    skip_reason=no-parent
    return 1
  fi
  if [ -L "$real_parent/$base" ]; then
    skip_reason=symlink
    return 1
  fi
  resolve_parent "$real_parent"
  rc=$?
  [ "$rc" -eq 142 ] && return 142
  if [ "$rc" -ne 0 ]; then
    skip_reason="$parent_reason"
    return 1
  fi
  target_root="$parent_root"
  files="${files:+$files,}$real_parent/$base"
  return 0
}

# パス $1 が、検査を定めるパス（check_paths）に当たるか（文字列の照合だけ）
is_check_path() {
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    case "$c" in
      */) case "$1" in *"/$c"*) return 0 ;; esac ;;
      *) case "$1" in *"/$c") return 0 ;; esac ;;
    esac
  done <<EOF
$check_paths
EOF
  return 1
}

# --- ここから本体 ---

# 起動元の根を、このファイルの置き場から決める
self="${BASH_SOURCE[0]}"
case "$self" in
  */*) self_dir="${self%/*}" ;;
  *) self_dir="." ;;
esac
here="$(real_dir "$self_dir")"
[ -n "$here" ] && origin="$(real_dir "$here/../..")"

case "$caller" in
  claude|codex) ;;
  *) caller="unknown"; launch_failed "呼び出し元の名前が claude でも codex でもありません" ;;
esac
if [ -z "$origin" ] || [ -L "$self" ]; then
  launch_failed "起動元の根を、スクリプトの置き場から決められません"
fi
if ! command -v perl > /dev/null 2>&1; then
  result=launch-failed
  emit_fixed
  write_log
  exit 0
fi
tmp="$(mktemp -d 2>/dev/null)" || tmp=""
[ -n "$tmp" ] && [ -d "$tmp" ] || launch_failed "一時ディレクトリを作れません"
check_paths="$(check_paths_of_origin)"
read_docs_cmd

# 入力の変換（標準入力を、そのまま渡す）
run_limited "$(remaining)" perl -e "$PATHS_PL" "$caller" "$MAX_PATHS" "$MAX_INPUT_BYTES" "$check_paths" > "$tmp/paths" 2> "$tmp/paths.err"
rc=$?
if [ "$rc" -eq 142 ]; then
  add_message "早期通知: フックの入力の変換が、時間切れ（上限 $TIME_LIMIT 秒）で終わりませんでした。文書の検査は動かしていません。"
  add_result timeout
  finish
elif [ "$rc" -eq 3 ]; then
  reason="$(head -n 1 "$tmp/paths.err" 2>/dev/null | tr -cd 'a-z-')"
  add_message "早期通知: フックの入力の形が、想定と違います（${reason:-unknown}）。道具の版が変わって、入力の形が変わった見込みです。scripts/harness/notify.sh の入力の変換を、規約の正本で直して写しを更新してください。文書の検査は動かしていません。"
  add_result input-shape
  finish
elif [ "$rc" -eq 5 ]; then
  add_message "早期通知: フックの入力が大きすぎて（$((MAX_INPUT_BYTES / 1048576)) MiB を超える）、書いたファイルを調べていません。文書の検査は動かしていません。文書を書いたときは、$DOCS_CMD で確かめてください。"
  add_result too-large
  finish
elif [ "$rc" -ne 0 ]; then
  launch_failed "入力の変換が、終了コード $rc で終わりました"
fi

# パスの判定と、根の重複の除去。時間の上限と、パスの数の上限に達したら、残りを読まずに打ち切って、知らせる
roots=()
judged=0
unjudged_time=0
unjudged_count=0
while IFS= read -r -d '' record; do
  case "$record" in
    '!too-many')
      unjudged_count=1
      break
      ;;
    '!not-md:'[1-9]*)
      n="${record#!not-md:}"
      case "$n" in
        *[!0-9]*|??????????*) ;;
        *) not_md_count=$((not_md_count + n)) ;;
      esac
      continue
      ;;
  esac
  if [ "$(remaining)" -le 0 ]; then
    unjudged_time=1
    break
  fi
  if [ "$judged" -ge "$MAX_PATHS" ]; then
    unjudged_count=1
    break
  fi
  judged=$((judged + 1))
  classify_path "$record"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    seen=0
    for r in ${roots[@]+"${roots[@]}"}; do
      [ "$r" = "$target_root" ] && seen=1
    done
    [ "$seen" -eq 1 ] || roots[${#roots[@]}]="$target_root"
  elif [ "$rc" -eq 142 ]; then
    unjudged_time=1
    break
  else
    skipped_reasons="${skipped_reasons:+$skipped_reasons }$skip_reason"
  fi
done < "$tmp/paths"

if [ "$unjudged_time" -eq 1 ]; then
  add_message "早期通知: 書いたファイルのパスの判定が、時間切れ（全体の上限 $TIME_LIMIT 秒）で終わりませんでした。判定していないパスがあり、その文書は検査していません。$DOCS_CMD で確かめてください。"
  add_result timeout
fi
if [ "$unjudged_count" -eq 1 ]; then
  add_message "早期通知: 1 回の書き込みの文書のパスが多すぎて（$MAX_PATHS 件を超える）、検査していないものがあります。$DOCS_CMD で確かめてください。"
  add_result too-many-paths
fi
if [ "${#roots[@]}" -eq 0 ]; then
  finish
fi

origin_name="${origin##*/}"
over=$((${#roots[@]} - MAX_ROOTS))
no_time=0
i=0
for root in "${roots[@]}"; do
  i=$((i + 1))
  [ "$i" -le "$MAX_ROOTS" ] || break
  left="$(remaining)"
  if [ "$left" -le 0 ]; then
    no_time=$((no_time + 1))
    continue
  fi
  name="${root##*/}"
  checked="${checked:+$checked,}$root"
  run_limited "$left" /bin/bash "$origin/scripts/harness/check-docs.sh" --root "$root" > "$tmp/out" 2>&1 < /dev/null
  rc=$?
  if [ "$rc" -eq 0 ]; then
    add_result pass
  elif [ "$rc" -eq 142 ]; then
    add_message "早期通知: 作業ツリー「${name}」の文書の検査が、時間切れ（全体の上限 $TIME_LIMIT 秒）で終わりませんでした。$DOCS_CMD で確かめてください。"
    add_result timeout
  elif [ "$rc" -eq 1 ]; then
    add_message "早期通知: 作業ツリー「${name}」の文書の検査（${DOCS_CMD}）が不合格です。起動元（${origin_name}）の検査で確かめました。起動元と版が違う作業ツリーでは、その作業ツリー自身の $DOCS_CMD の結果を優先してください。検査の出力の末尾:
$(tail -n "$TAIL_LINES" "$tmp/out" 2>/dev/null)"
    add_result fail
  else
    # この枝では、検査の出力を文面に入れない（シェルの誤りの表示などに、起動元の絶対パスが入りうるため）
    add_message "早期通知: 作業ツリー「${name}」の文書の検査を実行できませんでした（起動元（${origin_name}）の検査の終了コード ${rc}）。$DOCS_CMD で確かめてください。"
    add_result check-error
  fi
done

if [ "$no_time" -gt 0 ]; then
  add_message "早期通知: 時間の上限（$TIME_LIMIT 秒）に達したので、検査しなかった作業ツリーがあります（$no_time 個）。"
  add_result timeout
fi
if [ "$over" -gt 0 ]; then
  add_message "早期通知: 1 回の通知で検査する作業ツリーは $MAX_ROOTS 個までです。検査しなかった作業ツリーがあります（$over 個）。"
  add_result over-limit
fi

finish
