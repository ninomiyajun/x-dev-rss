#!/usr/bin/env node
// harness-copy: source=home/agents/skills/project-harness-init/assets/parts/node-secrets/assets/check-secrets.mjs
// harness-copy: version=rules-2026.11.13-1
// harness-copy: sha256=9212d9bed906a18c3cbd9de974607cce6e7b901ce5b1af2e190cfdbd00de53c4
// harness-copy: この 4 行と本体は手で変えない。正本を直して project-harness-init の「導入済みのプロジェクトの更新」で置き換える
// 秘匿値の検査の本体。入口は scripts/harness/check-secrets.sh（作業ツリーは引数なし、push する範囲は --commits）。
// CI はこのファイルを node で直接呼ぶ（npm の pre と post のスクリプトを動かさないため）。
//
// 2 つの調べ方がある。
//   作業ツリー（引数なし）: git の一覧（追跡済みのファイルと、.gitignore で除外していない未追跡のファイル）を、
//     作業ツリーの現在の中身で調べる。
//   コミット（--commits [--remote <名前>] [git rev-list の引数]）: 指定した範囲の各コミットに記録された中身を、
//     git から取り出して調べる。範囲のコミットメッセージと、手元のすべての注釈付きのタグの注釈も、一時ファイルに書いて
//     secretlint と単純な内容検査の両方で調べる。
//     範囲を省くと「HEAD --branches --tags --not --remotes=<名前>」（手元のすべてのブランチとタグ、HEAD から
//     到達でき、push 先のリモートの追跡ブランチから到達できないコミット。名前の既定は origin。初回の push ではすべて）。
//     範囲のコミットが 0 件でも、タグの注釈は調べる。
//
// どちらも次の場合は失敗にする。
//   - 一覧にあるのに検査できなかったファイル（作業ツリーで削除したものを除く）
//   - シンボリックリンク
//   - 中身に NUL バイトを含み、既知のバイナリの拡張子（BINARY_EXTS）でないファイル（UTF-16 で書いた文字のファイルなど。
//     secretlint も単純な内容検査も、中の文字を読めないため）
//   - secretlint の除外のファイル（名前が .secretlintignore で始まるもの）と、secretlint の無効化のコメント
//   - 秘匿値が見つかったファイル、コミットメッセージ、タグの注釈
//   - NUL バイトか secretlint の無効化のコメントを含むコミットメッセージとタグの注釈
//   - 作業ツリーと --file の検査で、secretlint の既定の対象外の名前のファイルの写しが、secretlint の結果に出なかったとき
//   - バイナリのファイルから取り出した文字列の写しが、secretlint の結果に出なかったか、文字のファイルとして調べられなかったとき
// secretlint が既定で対象外にするファイル（.secretlintrc.* など）は、この中の単純な内容検査（SIMPLE_PATTERNS）で調べ、
// 加えて、リポジトリの外の一時ディレクトリへ写した中身を secretlint にも掛ける（cwd の外では既定の対象外が効かないため）。
// 文字のファイルでないファイルも、単純な内容検査で調べる。既知のバイナリの拡張子のファイルは、UTF-16LE と UTF-16BE で
// 読んだ中身も同じ検査に掛ける。コミットメッセージとタグの注釈は、secretlint と単純な内容検査の両方に掛ける。
// バイナリのファイル（既知のバイナリの拡張子のファイルと、secretlint がバイナリと報告したファイル）は、secretlint の規則の
// 多くが文字のファイルしか調べず、プロジェクトが .secretlintrc.json に足した規則（pattern の規則）も掛からない。そこで、
// 中身から文字列を読みごとに取り出して一時ディレクトリの extracted/<通し番号>-<読みの番号>.txt に書き、その写しを secretlint の全規則に掛ける
// （extractStrings。所見は元のファイルの札で出す）。限界: UTF-32 で書かれた値、圧縮された中身（PNG の圧縮した文字の塊、画像の
// 本体、zip の中身など）、画像に写った文字は見つけられない。
// 失敗の一覧には、どのコミットかタグかの札だけを出し、見つかった値は出さない（値を伏せた表示は secretlint に任せる）。
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const SECRETLINT = path.join(ROOT, "node_modules", ".bin", "secretlint");
const CONFIG = path.join(ROOT, ".secretlintrc.json");
// secretlint は、この名前のファイルを各ディレクトリで除外の設定として読む。既定の名前（.secretlintignore）を
// 使わせないため、存在しない名前を渡す。
const UNUSED_IGNORE_NAME = ".harness-secretlintignore-unused";
// secretlint の無効化のコメントの目印。このファイル自身が一致しないよう、2 つに分けて書く。
const DISABLE_MARK = Buffer.from("secretlint" + "-disable");
// secretlint の 1 回の起動に渡すファイルの上限（引数の長さの上限を超えないため）
const SECRETLINT_CHUNK_FILES = 200;
const SECRETLINT_CHUNK_BYTES = 64 * 1024;
// バイナリから取り出した文字列の写しは、1 つのファイルから読みごとに最大 5 つでき、パスが短いので、1 回の起動に多く渡す
// （起動の回数を増やさず、所要時間を抑えるため。引数の長さは、下の上限でも OS の上限より十分に小さい）
const EXTRACTED_CHUNK_FILES = 2000;
const EXTRACTED_CHUNK_BYTES = 256 * 1024;
// git cat-file --batch の 1 回の起動で取り出す数
const CAT_FILE_CHUNK = 1000;

// secretlint が既定で対象外にするファイル（node_modules/secretlint/src/search.ts の DEFAULT_IGNORE_PATTERNS）。
const isSecretlintDefaultExcluded = (rel) => {
  const parts = rel.split("/");
  if (parts.includes(".git") || parts.includes("node_modules")) return true;
  const base = parts[parts.length - 1];
  return /^\.secretlintrc(\.(json|ya?ml|js))?$/.test(base) || base.startsWith(".secretlintignore");
};

// 単純な内容検査で探す形（代表的な鍵とトークンの接頭辞）。secretlint の規則より粗い。
// 正規表現は (?:…) で囲む（意味は変わらない。スラッシュの直後に英字が来る字句を、絶対パスの形の検査が拾わないため）。
const SIMPLE_PATTERNS = [
  ["GitHub のトークン", /(?:gh[pousr]_[A-Za-z0-9]{36,})/],
  ["GitHub の細かい権限のトークン", /(?:github_pat_[A-Za-z0-9_]{22,})/],
  ["Anthropic の鍵・トークン", /(?:sk-ant-[a-z0-9]+-[A-Za-z0-9_-]{20,})/],
  ["OpenAI などの sk- の鍵", /\bsk-[A-Za-z0-9_-]{20,}/],
  ["AWS のアクセスキー", /(?:AKIA[0-9A-Z]{16})/],
  ["Slack のトークン", /(?:xox[abposr]-[A-Za-z0-9-]{10,})/],
  ["Google の API キー", /(?:AIza[0-9A-Za-z_-]{35})/],
  ["npm のトークン", /(?:npm_[A-Za-z0-9]{36})/],
  ["秘密鍵", /(?:BEGIN [A-Z ]*PRIVATE KEY)/],
];

const die = (msg) => {
  console.error(`check-secrets: ${msg}`);
  process.exit(2);
};

const git = (args, input) => {
  const r = spawnSync("git", ["-C", ROOT, "-c", "core.quotePath=false", ...args], { maxBuffer: 1 << 30, input });
  if (r.error) die(`git を実行できません: ${r.error.message}`);
  return r;
};
const gitOk = (args, input) => {
  const r = git(args, input);
  if (r.status !== 0) die(`git ${args.join(" ")} が失敗しました: ${r.stderr.toString()}`);
  return r.stdout;
};
// 処理は同期で進むので、区切りごとにイベントループへ戻し、SIGINT と SIGTERM の処理を動かす
const yieldForSignals = () => new Promise((resolve) => setImmediate(resolve));
const splitNul = (buf) => buf.toString("utf8").split("\0").filter((s) => s !== "");

// git cat-file --batch で、オブジェクトの中身をまとめて取り出す。onObject(sha, 種類, 中身) を順に呼ぶ。
const catBatch = async (shas, onObject) => {
  for (let i = 0; i < shas.length; i += CAT_FILE_CHUNK) {
    await yieldForSignals();
    const chunk = shas.slice(i, i + CAT_FILE_CHUNK);
    const out = gitOk(["cat-file", "--batch"], chunk.join("\n") + "\n");
    let pos = 0;
    for (const want of chunk) {
      const nl = out.indexOf(0x0a, pos);
      if (nl < 0) die(`git cat-file の出力が途中で終わりました（${want}）`);
      const [sha, type, size] = out.subarray(pos, nl).toString("utf8").split(" ");
      if (sha !== want || type === "missing" || size === undefined) die(`git cat-file で ${want} を取り出せません`);
      const start = nl + 1;
      const end = start + Number(size);
      onObject(sha, type, out.subarray(start, end));
      pos = end + 1; // 中身の後の改行
    }
  }
};

const problems = {
  unreadable: [], symlinks: [], nulFiles: [], nulTexts: [], ignoreFiles: [], disableComments: [], disableTexts: [], unscannedCopies: [],
  unscannedExtracted: [],
};
const pushOnce = (list, x) => {
  if (!list.includes(x)) list.push(x);
};

// 中身に NUL バイトを含んでよい、既知のバイナリの拡張子（今のリポジトリにあるものと、よくある画像とフォント）。
// これ以外の拡張子で NUL バイトを含むファイルは、UTF-16 の文字のファイルなどの読めないファイルとして失敗にする。
const BINARY_EXTS = new Set(["ico", "png", "jpg", "jpeg", "gif", "webp", "avif", "bmp", "woff", "woff2", "ttf", "otf", "eot"]);
const isKnownBinary = (rel) => BINARY_EXTS.has(path.extname(rel).slice(1).toLowerCase());

// 作業ツリーの一覧を作る。返り値の各要素は { abs: 読むパス, rel: リポジトリでのパス, label: 表示名 }
// （コミットメッセージとタグの注釈の一時ファイルは、ほかに isText: true を持つ）。
const collectWorktree = () => {
  const listed = [...new Set(splitNul(gitOk(["ls-files", "-z", "--cached", "--others", "--exclude-standard"])))];
  const deleted = new Set(splitNul(gitOk(["ls-files", "-z", "--deleted"])));
  const entries = [];
  let deletedCount = 0;
  for (const rel of listed) {
    const abs = path.join(ROOT, rel);
    let st;
    try {
      st = fs.lstatSync(abs);
    } catch {
      if (deleted.has(rel)) deletedCount += 1;
      else problems.unreadable.push(rel);
      continue;
    }
    if (st.isSymbolicLink()) problems.symlinks.push(rel);
    else if (st.isFile()) entries.push({ abs, rel, label: rel });
    else problems.unreadable.push(rel); // ディレクトリ（サブモジュールなど）
  }
  return { entries, note: deletedCount > 0 ? `作業ツリーで削除した ${deletedCount} 件は対象外` : "" };
};

// --commits の引数を読む。返り値は git rev-list に渡す引数。
const parseCommitArgs = (args) => {
  let remote = null;
  if (args[0] === "--remote") {
    remote = args[1];
    if (!remote || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(remote)) die("--remote の後にリモートの名前を書いてください");
    args = args.slice(2);
  }
  if (args.length > 0) {
    if (remote !== null) die("--remote と範囲の指定は一緒に使えません");
    return args;
  }
  // push するのは HEAD だけとは限らない（別のブランチやタグ）ので、手元のすべてのブランチとタグから辿る
  const hasHead = git(["rev-parse", "--verify", "-q", "HEAD"]).status === 0;
  const hasRefs = gitOk(["for-each-ref", "--count=1", "refs/heads", "refs/tags"]).length > 0;
  if (!hasHead && !hasRefs) {
    console.log("check-secrets: コミットがまだ無いので、検査するコミットはありません");
    process.exit(0);
  }
  return [...(hasHead ? ["HEAD"] : []), "--branches", "--tags", "--not", `--remotes=${remote ?? "origin"}`];
};

// コミットの中身を一時ディレクトリへ取り出して一覧を作る。同じパスと同じ中身の組は 1 回だけ調べる。
// 範囲のコミットメッセージと、手元の注釈付きのタグの注釈は、取り出した生のバイト列のまま一時ディレクトリの texts/ に
// 1 つずつ書き、isText の付いた要素として一覧に加える（secretlint と単純な内容検査の両方に掛けるため）。
const collectCommits = async (revArgs, tmp) => {
  const commits = gitOk(["rev-list", ...revArgs, "--"]).toString().split("\n").filter(Boolean);
  // 0 件でも終えない（タグの注釈は範囲と関係なく調べる）
  if (commits.length === 0) console.log("check-secrets: 検査するコミットはありません（タグの注釈は調べます）");
  const seen = new Map();
  for (const commit of commits) {
    await yieldForSignals();
    const short = commit.slice(0, 12);
    for (const line of splitNul(gitOk(["ls-tree", "-r", "-z", "--full-tree", commit]))) {
      const tab = line.indexOf("\t");
      const [mode, type, sha] = line.slice(0, tab).split(" ");
      const rel = line.slice(tab + 1);
      const label = `${short}:${rel}`;
      if (mode === "120000") {
        problems.symlinks.push(label);
        continue;
      }
      if (type !== "blob" || rel.split("/").some((p) => p === ".." || p === "." || p === "")) {
        problems.unreadable.push(label);
        continue;
      }
      const key = `${sha}\0${rel}`;
      if (seen.has(key)) continue;
      seen.set(key, { abs: path.join(tmp, "tree", sha, rel), rel, label, sha });
    }
  }
  const pathsBySha = new Map();
  for (const e of seen.values()) pathsBySha.set(e.sha, [...(pathsBySha.get(e.sha) ?? []), e.abs]);
  await catBatch([...pathsBySha.keys()], (sha, type, body) => {
    for (const abs of pathsBySha.get(sha)) {
      fs.mkdirSync(path.dirname(abs), { recursive: true });
      fs.writeFileSync(abs, body);
    }
  });

  // コミットメッセージとタグの注釈（見出しの行の後ろ）。タグはどれが push されるか分からないので、手元のすべてを調べる。
  const texts = [];
  const textDir = path.join(tmp, "texts");
  fs.mkdirSync(textDir, { recursive: true });
  const addText = (label, body) => {
    const i = body.indexOf("\n\n");
    const text = i < 0 ? Buffer.alloc(0) : body.subarray(i + 2);
    if (text.length === 0) return; // 空のメッセージには調べる中身が無い
    const rel = `texts/${texts.length + 1}.txt`;
    const abs = path.join(tmp, rel);
    fs.writeFileSync(abs, text);
    texts.push({ abs, rel, label, isText: true });
  };
  await catBatch(commits, (sha, type, body) => addText(`${sha.slice(0, 12)}（コミットメッセージ）`, body));
  const tags = gitOk(["for-each-ref", "--format=%(objecttype) %(objectname) %(refname)", "refs/tags"])
    .toString()
    .split("\n")
    .filter((l) => l.startsWith("tag "))
    .map((l) => l.split(" "));
  const tagNames = new Map(tags.map(([, sha, ref]) => [sha, ref]));
  await catBatch([...tagNames.keys()], (sha, type, body) => addText(`${tagNames.get(sha)}（タグの注釈）`, body));

  return {
    entries: [...seen.values(), ...texts],
    note: `コミット ${commits.length} 件のメッセージと、注釈付きのタグ ${tagNames.size} 件の注釈も、secretlint と単純な内容検査で調べた`,
  };
};

const simpleScanText = (text) => SIMPLE_PATTERNS.filter(([, re]) => re.test(text)).map(([name]) => name);
// 既知のバイナリの拡張子のファイルは、UTF-16LE と UTF-16BE で読んだ中身も調べる（偶数と奇数の両方の位置から読む）
const simpleScan = (entry) => {
  const buf = fs.readFileSync(entry.abs);
  const views = [buf.toString("latin1")];
  if (isKnownBinary(entry.rel)) {
    for (const start of [0, 1]) {
      const part = Buffer.from(buf.subarray(start, start + ((buf.length - start) & ~1)));
      views.push(part.toString("utf16le"));
      views.push(part.swap16().toString("utf16le"));
    }
  }
  return [...new Set(views.flatMap(simpleScanText))];
};

// バイナリのファイルの中身から、文字列を取り出す。latin1 で読んだ中身と、UTF-16LE・UTF-16BE で偶数と奇数の位置から読んだ
// 4 つの中身のそれぞれで、印字可能な ASCII（0x20-0x7E とタブ）以外の文字の連なりを 1 つの改行に置き換える。短い並びも
// 捨てない（名前と値が別の行に分かれても、改行は正規表現の空白に当たるので、名前と値をまたぐ規則が働く）。上限で途中を
// 切り捨てることはしない。読みごとに別の文字列として返す（1 つにつながないのは、大きなバイナリで文字列の長さの上限に
// 当たらないため）。印字可能な文字が 1 つも無い読みは返さない。返り値は [読みの番号（1〜5）, 文字列] の並び。
const NON_PRINTABLE_RUNS = /[^\t\x20-\x7e]+/g;
const HAS_PRINTABLE = /[\t\x20-\x7e]/;
const extractStrings = (buf) => {
  const readers = [() => buf.toString("latin1")];
  for (const start of [0, 1]) {
    const part = () => Buffer.from(buf.subarray(start, start + ((buf.length - start) & ~1)));
    readers.push(() => part().toString("utf16le"));
    readers.push(() => part().swap16().toString("utf16le"));
  }
  const out = [];
  readers.forEach((read, i) => {
    const v = read();
    if (HAS_PRINTABLE.test(v)) out.push([i + 1, v.replace(NON_PRINTABLE_RUNS, "\n")]);
  });
  return out;
};
// 取り出した文字列の中の secretlint の無効化のコメントの目印を、働かない形に替える（取り出した文字列に無効化のコメントが
// あっても、所見を消させないため。目印があったことは、元のファイルの無効化のコメントとして別に失敗にする）
const DISABLE_MARK_RE = new RegExp(DISABLE_MARK.toString("latin1"), "g");
const neutralizeDisable = (text) => text.replace(DISABLE_MARK_RE, "secretlint_disable_neutralized");

// ファイルを、引数の長さの上限を超えない組に分ける
const chunkFiles = (files, maxFiles = SECRETLINT_CHUNK_FILES, maxBytes = SECRETLINT_CHUNK_BYTES) => {
  const chunks = [];
  let cur = [];
  let bytes = 0;
  for (const f of files) {
    const len = Buffer.byteLength(f) + 1;
    if (cur.length > 0 && (cur.length >= maxFiles || bytes + len > maxBytes)) {
      chunks.push(cur);
      cur = [];
      bytes = 0;
    }
    cur.push(f);
    bytes += len;
  }
  if (cur.length > 0) chunks.push(cur);
  return chunks;
};

const main = async () => {
  const argv = process.argv.slice(2);
  const commitMode = argv[0] === "--commits";
  // --file <絶対パス>: そのファイル 1 つだけを調べる（定期の走査が、報告を公開する前に使う）
  const fileMode = argv[0] === "--file";
  if (argv.length > 0 && !commitMode && !fileMode) die(`知らない引数です: ${argv[0]}（使えるのは --commits と --file <絶対パス> だけ）`);
  if (fileMode) {
    let st = null;
    try { st = argv.length === 2 && path.isAbsolute(argv[1]) ? fs.lstatSync(argv[1]) : null; } catch { st = null; }
    if (!st || !st.isFile()) die("--file の後に、調べる通常のファイルの絶対パスを 1 つだけ書いてください");
    // secretlint が報告するパスと照らせるよう、実体のパスに解決してから使う（一時ディレクトリがシンボリックリンクを経る環境など）
    argv[1] = fs.realpathSync(argv[1]);
  }
  if (!fs.existsSync(SECRETLINT)) die("secretlint がありません。先に npm ci を実行してください");
  const revArgs = commitMode ? parseCommitArgs(argv.slice(1)) : [];

  // 終了のときと、SIGINT・SIGTERM で止めたときに一時ディレクトリを消す（取り出したファイルと報告を残さない）
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "harness-secrets-"));
  const cleanup = () => fs.rmSync(tmp, { recursive: true, force: true });
  process.on("exit", cleanup);
  for (const [sig, code] of [["SIGINT", 130], ["SIGTERM", 143]]) {
    process.on(sig, () => {
      cleanup();
      console.error(`check-secrets: ${sig} で止めました`);
      process.exit(code);
    });
  }
  {
    const one = () => ({ entries: [{ abs: argv[1], rel: path.basename(argv[1]), label: path.basename(argv[1]) }], note: "" });
    const { entries, note } = commitMode ? await collectCommits(revArgs, tmp) : fileMode ? one() : collectWorktree();
    // コミットの検査は、範囲のコミットが 0 件でもタグの注釈を調べるので、ファイルが無くても続ける
    if (!commitMode && entries.length === 0 && problems.symlinks.length === 0 && problems.unreadable.length === 0) {
      die("対象のファイルがありません");
    }

    // secretlint の除外を、ファイルを足すだけで働かせないための検査と、NUL バイトを含むファイルの検査
    //
    // secretlint の既定の対象外は、cwd（リポジトリ）からの相対の glob で効き、cwd の外のパスには効かない
    // （@secretlint/walker の ignore-stack.js:79-86 が、対象のパスを含まないディレクトリの段の照合を飛ばす。secretlint 13.0.7 で確認）。
    // コミットの中身はリポジトリの外の一時ディレクトリに取り出すので、そのまま secretlint に掛かる。作業ツリーと --file の検査では、
    // 既定の対象外の名前のファイルを、単純な内容検査で調べるのに加え、ここで読んだ中身をそのまま一時ディレクトリの
    // excluded/<通し番号>/<rel> へ写し、写しを secretlint に渡す（通し番号は、大文字と小文字を区別しない一時領域で、
    // 大文字と小文字だけが違うパスの写しが重なって中身を上書きしないため）。写しの要素は { abs: 写しのパス, rel, label: 元の札, src: 元の要素 }。
    // 限界: 規則の中には、ファイルのパスで適用を決めるもの（pattern の規則の filePathGlobs）がある。写しのパスは一時ディレクトリの
    // 下の excluded/<通し番号>/<rel> なので、パスで適用を決める条件は全般に、元のパスと違う結果になりうる（元の絶対パスに頼る
    // 条件だけでなく、否定の glob も。たとえば ["**/.secretlintrc.json", "!**/excluded/**"] は、元のパスでは当たり、写しのパスでは
    // 外れる）。コミットの検査も同じ性質を持つ。配るひな形の .secretlintrc.json は filePathGlobs を使っていない。
    const readable = [];
    const forSimple = []; // secretlint の既定の対象外の元のファイル（単純な内容検査で調べる）
    const forSecretlint = [];
    for (const e of entries) {
      if (!e.isText && (path.basename(e.rel).startsWith(".secretlintignore") || path.basename(e.rel) === UNUSED_IGNORE_NAME)) {
        problems.ignoreFiles.push(e.label);
      }
      const buf = fs.readFileSync(e.abs);
      if (buf.includes(DISABLE_MARK)) (e.isText ? problems.disableTexts : problems.disableComments).push(e.label);
      if (buf.includes(0) && !isKnownBinary(e.rel)) {
        (e.isText ? problems.nulTexts : problems.nulFiles).push(e.label);
        continue;
      }
      readable.push(e);
      if (!commitMode && isSecretlintDefaultExcluded(e.rel)) {
        forSimple.push(e);
        const abs = path.join(tmp, "excluded", String(forSimple.length), e.rel);
        fs.mkdirSync(path.dirname(abs), { recursive: true });
        fs.writeFileSync(abs, buf);
        forSecretlint.push({ abs, rel: e.rel, label: e.label, src: e });
      } else {
        forSecretlint.push(e);
      }
    }
    const excludedCount = forSimple.length; // secretlint の既定の対象外で、写しを secretlint にも掛けたファイル
    const simpleSet = new Set(forSimple);
    const findings = [];
    let checkedBySecretlint = 0;

    const common = ["--secretlintrc", CONFIG, "--secretlintignore", UNUSED_IGNORE_NAME, "--no-gitignore", "--no-glob"];
    const seenAbs = new Set();
    const withFindings = [];
    // ファイルの組を secretlint に JSON の報告で掛け、結果ごとに onResult(要素, 結果) を呼ぶ
    const runSecretlint = async (list, onResult, limits = []) => {
      const byPath = new Map(list.map((e) => [e.abs, e]));
      for (const files of chunkFiles(list.map((e) => e.abs), ...limits)) {
        await yieldForSignals();
        const report = path.join(tmp, "report.json");
        const r = spawnSync(SECRETLINT, [...common, "--format", "json", "--output", report, "--", ...files], {
          cwd: ROOT,
          stdio: ["ignore", "inherit", "inherit"],
        });
        await yieldForSignals(); // 子のプロセスが SIGINT で止まった場合は、ここで止める
        if (r.status !== 0 || !fs.existsSync(report)) die(`secretlint が異常終了しました（終了コード ${r.status}）`);
        const results = JSON.parse(fs.readFileSync(report, "utf8"));
        fs.rmSync(report);
        for (const res of results) {
          const e = byPath.get(path.resolve(res.filePath));
          if (e) onResult(e, res);
        }
      }
    };
    const reportedBinary = new Set(); // secretlint がバイナリと報告した元の要素
    await runSecretlint(forSecretlint, (e, res) => {
      seenAbs.add(e.abs);
      if (res.messages.length > 0) withFindings.push(e);
      checkedBySecretlint += 1;
      // 単純な内容検査に足すのは元の要素（写しの元がすでに入っていれば足さず、同じ札の所見を 2 回出さない）
      const orig = e.src ?? e;
      if (res.sourceContentType === "binary") {
        reportedBinary.add(orig);
        if (!simpleSet.has(orig)) {
          simpleSet.add(orig);
          forSimple.push(orig); // secretlint の規則の多くは文字のファイルだけを調べるため
        }
      }
    });
    for (const e of forSecretlint) {
      if (!seenAbs.has(e.abs)) (e.src ? problems.unscannedCopies : problems.unreadable).push(e.label);
    }

    // バイナリのファイル（既知のバイナリの拡張子のものと、secretlint がバイナリと報告したもの）から文字列を取り出し、
    // 読みごとに一時ディレクトリの extracted/<通し番号>-<読みの番号>.txt に書いて、secretlint の全規則（推奨の一式と、
    // プロジェクトが足した pattern の規則）に掛ける。写しの名前に元の拡張子を残さない（secretlint が文字のファイルとして
    // 読むため）。取り出した文字列の無い読みは写しを作らない。写しの要素は
    // { abs: 写しのパス, rel, label: 元の札, src: 元の要素, extracted: true }。所見は元の札で 1 回だけ出す。
    // 取り出した文字列に無効化のコメントの目印があれば、元の札で無効化のコメントとして失敗にし、写しでは目印を働かない形に替える
    const extracted = [];
    const extractedOrigs = new Set();
    for (const e of forSecretlint) {
      const orig = e.src ?? e;
      if (extractedOrigs.has(orig) || !(isKnownBinary(orig.rel) || reportedBinary.has(orig))) continue;
      extractedOrigs.add(orig);
      const n = extractedOrigs.size;
      for (const [view, text] of extractStrings(fs.readFileSync(orig.abs))) {
        if (text.includes(DISABLE_MARK.toString("latin1"))) pushOnce(orig.isText ? problems.disableTexts : problems.disableComments, orig.label);
        const abs = path.join(tmp, "extracted", `${n}-${view}.txt`);
        fs.mkdirSync(path.dirname(abs), { recursive: true });
        fs.writeFileSync(abs, neutralizeDisable(text), "latin1");
        extracted.push({ abs, rel: orig.rel, label: orig.label, src: orig, extracted: true });
      }
    }
    const seenExtracted = new Set();
    const extractedFindingOrigs = new Set();
    await runSecretlint(extracted, (e, res) => {
      seenExtracted.add(e.abs);
      if (res.sourceContentType !== "text") pushOnce(problems.unscannedExtracted, e.label);
      else if (res.messages.length > 0) {
        withFindings.push(e);
        extractedFindingOrigs.add(e.src);
      }
    }, [EXTRACTED_CHUNK_FILES, EXTRACTED_CHUNK_BYTES]);
    for (const e of extracted) {
      if (!seenExtracted.has(e.abs)) pushOnce(problems.unscannedExtracted, e.label);
    }
    // 既知のバイナリの拡張子のファイルは、secretlint が文字のファイルと見なしても単純な内容検査に掛ける（UTF-16 の中身のため）
    for (const e of forSecretlint) {
      const orig = e.src ?? e;
      if (isKnownBinary(orig.rel) && !simpleSet.has(orig)) {
        simpleSet.add(orig);
        forSimple.push(orig);
      }
    }
    // --file のファイルと、コミットメッセージとタグの注釈には、単純な内容検査も必ず掛ける（--file は公開する前の最後の
    // 確かめなので、secretlint の規則の外の形も拾う。メッセージと注釈は、前から単純な内容検査で調べていた形を落とさない）
    for (const e of readable) {
      if ((fileMode || e.isText) && !simpleSet.has(e)) {
        simpleSet.add(e);
        forSimple.push(e);
      }
    }
    // 見つかった値を伏せた形で表示する（secretlint の既定の maskSecrets）。コミットの検査では、表示に出る一時ファイルの
    // パスが、どのコミットのファイルか、どのコミットメッセージかタグの注釈かを先に出す。作業ツリーと --file の検査でも、
    // 写しを表示に渡すファイルは、写しのパスがどのファイルかを先に出す
    const EXTRACTED_NOTE = "バイナリから取り出した文字列";
    for (const e of withFindings) {
      if (commitMode || e.src) console.error(`check-secrets: 次の表示の ${e.abs} は ${e.label}${e.extracted ? `（${EXTRACTED_NOTE}）` : ""}`);
    }
    for (const files of chunkFiles(withFindings.map((e) => e.abs))) {
      spawnSync(SECRETLINT, [...common, "--", ...files], { cwd: ROOT, stdio: "inherit" });
    }
    for (const e of withFindings) if (!e.extracted) findings.push(`${e.label}（secretlint）`);
    // 取り出した文字列の所見は、読みの写しがいくつ当たっても、元の札で 1 回だけ出す
    for (const orig of extractedFindingOrigs) findings.push(`${orig.label}（secretlint: ${EXTRACTED_NOTE}）`);
    for (const e of forSimple) {
      for (const name of simpleScan(e)) findings.push(`${e.label}（単純な内容検査: ${name}）`);
    }

    const summary =
      `secretlint で ${checkedBySecretlint} 件、単純な内容検査で ${forSimple.length} 件` +
      `（うち secretlint の既定の対象外で、写しを secretlint にも掛けた ${excludedCount} 件、` +
      `ほかに secretlint でも調べた ${forSimple.length - excludedCount} 件）` +
      `を調べました。バイナリのファイル ${extractedOrigs.size} 件から取り出した文字列（写し ${extracted.length} 件）も secretlint で調べました` +
      `${note ? `。${note}` : ""}`;
    console.log(`check-secrets: ${commitMode ? "コミットの中身" : fileMode ? "ファイル" : "作業ツリー"}: ${summary}`);

    let failed = false;
    const report = (list, title, fix) => {
      if (list.length === 0) return;
      failed = true;
      console.error(`check-secrets: NG: ${title}（${list.length} 件）`);
      for (const x of list) console.error(`  - ${x}`);
      console.error(`  直し方: ${fix}`);
    };
    report(problems.unreadable, "一覧にあるのに検査できなかったファイル", "ファイルの種類と読み取りの権限を確かめる。サブモジュールは使わない");
    report(
      problems.unscannedCopies,
      "secretlint が既定の対象外として調べなかった写し",
      "secretlint の版が既定の対象外の扱いを変えた可能性がある。check-secrets.mjs の写しの方式を見直す（TMPDIR がリポジトリの中にあるときも起きる）",
    );
    report(
      problems.unscannedExtracted,
      "バイナリのファイルから取り出した文字列を、secretlint が文字のファイルとして調べなかったもの",
      "secretlint の版が、文字のファイルの見分け方か結果の形を変えた可能性がある。check-secrets.mjs の取り出しの方式を見直す（TMPDIR がリポジトリの中にあるときも起きる）",
    );
    report(problems.symlinks, "シンボリックリンク", "シンボリックリンクをやめ、実体のファイルを置く（リンク先の中身は検査と食い違うため）");
    report(
      problems.nulFiles,
      "NUL バイトを含むファイル（UTF-16 で書いた文字のファイルなど）",
      `文字のファイルは UTF-8 で保存し直す（UTF-16 などの中身は検査で読めないため）。バイナリのファイルは既知の拡張子（${[...BINARY_EXTS].join("、")}）にする`,
    );
    report(
      problems.nulTexts,
      "NUL バイトを含むコミットメッセージとタグの注釈",
      "メッセージ（タグの注釈）から NUL を除いて作り直す（push していないコミットは rebase などでメッセージを直し、タグは注釈を直して作り直す。NUL を含む中身は検査で読めないため）",
    );
    report(problems.ignoreFiles, "secretlint の除外のファイル", "このファイルを消す。誤検出は .secretlintrc.json の規則の設定で直し、ADR に理由を書く");
    report(problems.disableComments, "secretlint の無効化のコメント", "コメントを消す。誤検出は .secretlintrc.json の規則の設定で直し、ADR に理由を書く");
    report(
      problems.disableTexts,
      "secretlint の無効化のコメントを含むコミットメッセージとタグの注釈",
      "メッセージからその語を消して書き直す（push していないコミットは rebase などでメッセージを直し、タグは注釈を直して作り直す）。誤検出は .secretlintrc.json の規則の設定で直し、ADR に理由を書く",
    );
    report(findings, "秘匿値の疑い", "値を消し、鍵を無効にして作り直す。コミット済みなら履歴（コミットメッセージとタグを含む）からも消す");
    if (failed) process.exit(1);
    console.log("check-secrets: 秘匿値は見つかりませんでした");
  }
};

// 想定しない誤り（読めないファイル、壊れた報告など）は、検査が動かなかったこととして終了コード 2 にする
try {
  await main();
} catch (err) {
  die(`想定しない誤りで止まりました: ${err && err.message ? err.message : String(err)}`);
}
