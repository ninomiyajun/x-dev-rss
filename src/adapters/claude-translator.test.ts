// 翻訳の外との接続の試験（計画の手順 5）。本物の claude は起動せず、試験が一時ディレクトリに作る
// 偽物の実行ファイル（#!/bin/sh のスクリプト）を claude のパスとして渡す。
import { test } from "node:test";
import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readFile, realpath, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { ALLOWED_ENV, createClaudeTranslator, hasLeak, showsOverageEnabled, systemPrompt, type ClaudeTranslatorOptions } from "./claude-translator.ts";
import { FAKE_SECRETS, FAKE_SECRET_VALUES, containsSecret } from "../app/fakes.ts";

/** 架空のトークンの文字列（XPJA-6）。秘匿値の検査（.secretlintrc.json の OAuth トークンの形）に当たらないよう、点で区切る。 */
const FAKE_TOKEN = "sk-ant-oat01-FAKE.not.a.real.token";

/** 子へ渡してはならない変数に架空の値を入れた親の環境（XPJA-6）。 */
const PARENT_ENV: Record<string, string> = {
  HOME: "/nonexistent/fake-home",
  USER: "fakeuser",
  LOGNAME: "fakeuser",
  TMPDIR: "/nonexistent/fake-tmp/",
  LANG: "en_US.UTF-8",
  PATH: "/nonexistent/should-not-pass",
  ...FAKE_SECRETS,
  ANTHROPIC_API_KEY: FAKE_TOKEN,
  ANTHROPIC_AUTH_TOKEN: FAKE_TOKEN,
  ANTHROPIC_BASE_URL: "https://example.invalid/fake-base",
  CLAUDE_CODE_OAUTH_TOKEN: FAKE_TOKEN,
  CLAUDE_CODE_USE_BEDROCK: "1",
  CLAUDECODE: "1",
};

const INIT = JSON.stringify({ type: "system", subtype: "init", apiKeySource: "none", tools: [], mcp_servers: [], model: "fake" });
const AUTH_OK = JSON.stringify({ loggedIn: true, authMethod: "claude.ai", apiProvider: "firstParty", note: FAKE_TOKEN });

function resultLine(result: unknown, extra: Record<string, unknown> = {}): string {
  return JSON.stringify({ type: "result", subtype: "success", is_error: false, result, note: FAKE_TOKEN, ...extra });
}

/** シェルの単一引用符で囲む。 */
function q(text: string): string {
  return `'${text.replace(/'/g, `'\\''`)}'`;
}

/** 行を標準出力へ出す sh の文。 */
function emit(...lines: string[]): string {
  return lines.map((l) => `printf '%s\\n' ${q(l)}`).join("\n");
}

const READ_STDIN = 'cat > "$D/stdin"';

type Fake = { dir: string; claudePath: string; workRoot: string };

/**
 * 偽物の claude を作る。auth status では authBody を、それ以外では、受け取った引数・環境・作業ディレクトリ・
 * 自分の番号を書いた後に body を動かす。どちらも標準エラーに架空のトークンを出す。
 */
async function makeFake(body: string, authBody = emit(AUTH_OK)): Promise<Fake> {
  const dir = await realpath(await mkdtemp(join(tmpdir(), "x-dev-rss-test-")));
  const workRoot = join(dir, "work");
  await mkdir(workRoot);
  const claudePath = join(dir, "claude");
  const script = [
    "#!/bin/sh",
    `D=${q(dir)}`,
    `echo ${q(FAKE_TOKEN)} >&2`,
    'if [ "$1" = auth ]; then',
    '  echo auth >> "$D/calls"',
    '  echo $$ > "$D/authpid"',
    authBody,
    "  exit 0",
    "fi",
    'echo translate >> "$D/calls"',
    'for a in "$@"; do printf \'%s\\0\' "$a"; done > "$D/args"',
    'env > "$D/env"',
    'pwd -P > "$D/cwd"',
    'echo $$ > "$D/pid"',
    body,
    "",
  ].join("\n");
  await writeFile(claudePath, script, { mode: 0o755 });
  return { dir, claudePath, workRoot };
}

function translator(fake: Fake, extra: Partial<ClaudeTranslatorOptions> = {}) {
  return createClaudeTranslator({ claudePath: fake.claudePath, env: PARENT_ENV, workRoot: fake.workRoot, timeoutMs: 10_000, graceMs: 1000, ...extra });
}

async function readOr(path: string): Promise<string | undefined> {
  try {
    return await readFile(path, "utf8");
  } catch {
    return undefined;
  }
}

async function calls(fake: Fake): Promise<string[]> {
  return ((await readOr(join(fake.dir, "calls"))) ?? "").split("\n").filter((l) => l !== "");
}

async function exists(path: string): Promise<boolean> {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}

/** ファイルができるまで待つ（回数の決まった待ち）。 */
async function waitFile(path: string): Promise<string> {
  for (let i = 0; i < 200; i += 1) {
    const text = await readOr(path);
    if (text !== undefined && text.trim() !== "") return text.trim();
    await delay(20);
  }
  throw new Error("待ちの上限");
}

/** プロセスのまとまりに生きたプロセスが残っていないか。 */
function groupGone(pid: string): boolean {
  try {
    process.kill(-Number(pid), 0);
    return false;
  } catch (err) {
    return (err as NodeJS.ErrnoException).code === "ESRCH";
  }
}

function activeHandles(): number {
  return process.getActiveResourcesInfo().filter((r) => r === "PipeWrap" || r === "ProcessWrap").length;
}

/** 試験の後始末と、どの場面にも共通の確かめ（作業ディレクトリが消えた、出力に秘匿値とトークンが無い、パイプが閉じた）。 */
async function finish(fake: Fake, result: unknown, handlesBefore: number): Promise<void> {
  const text = JSON.stringify(result);
  assert.ok(!containsSecret(text), "結果に秘匿値が無い");
  assert.ok(!text.includes(FAKE_TOKEN), "結果にトークンの文字列が無い");
  const cwd = await readOr(join(fake.dir, "cwd"));
  if (cwd !== undefined) assert.equal(await exists(cwd.trim()), false, "作業ディレクトリが消えている");
  for (const name of ["pid", "authpid"]) {
    const pid = await readOr(join(fake.dir, name));
    if (pid !== undefined) assert.ok(groupGone(pid.trim()), `${name} のまとまりが残っていない`);
  }
  await delay(10);
  assert.equal(activeHandles(), handlesBefore, "子のパイプとプロセスの握りが閉じている");
  await rm(fake.dir, { recursive: true, force: true });
}

const SUCCESS = [READ_STDIN, emit(INIT, resultLine("今日、新しいモデルをリリースします。"), JSON.stringify({ type: "rate_limit_event" }))].join("\n");

test("翻訳の接続: 成功すれば result の訳文を返し、引数・環境・標準入力・作業ディレクトリは決めたとおり（D3・D13・XPJA-6）", async () => {
  const before = activeHandles();
  const fake = await makeFake(SUCCESS);
  const original = "We're releasing a new model today.";
  const result = await translator(fake).translate(original, 1);
  assert.deepEqual(result, { ok: true, text: "今日、新しいモデルをリリースします。" });

  const stdin = await readFile(join(fake.dir, "stdin"), "utf8");
  const m = /^<post-([0-9a-f]{32})>\n([\s\S]*)\n<\/post-([0-9a-f]{32})>\n$/.exec(stdin);
  assert.ok(m, "標準入力は本文を包んだ文だけ");
  const marker = m[1] ?? "";
  assert.equal(m[2], original);
  assert.equal(m[3], marker);

  const args = (await readFile(join(fake.dir, "args"), "utf8")).split("\0").slice(0, -1);
  assert.deepEqual(args, [
    "-p",
    "--model",
    "haiku",
    "--setting-sources",
    "project",
    "--no-session-persistence",
    "--tools",
    "",
    "--strict-mcp-config",
    "--disable-slash-commands",
    "--max-budget-usd",
    "0.09",
    "--system-prompt",
    systemPrompt(marker),
    "--output-format",
    "stream-json",
    "--verbose",
  ]);

  const env = new Map(
    (await readFile(join(fake.dir, "env"), "utf8"))
      .split("\n")
      .filter((l) => l.includes("="))
      .map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)] as const),
  );
  // シェルが自分で足す変数を除くと、許す変数の表のもの（親に在るものだけ）と固定の PATH だけ。
  const shellAdded = new Set(["PWD", "OLDPWD", "SHLVL", "_"]);
  const names = [...env.keys()].filter((k) => !shellAdded.has(k)).sort();
  assert.deepEqual(names, ["HOME", "LANG", "LOGNAME", "PATH", "TMPDIR", "USER"]);
  assert.equal(env.get("PATH"), "/usr/bin:/bin:/usr/sbin:/sbin");
  assert.equal(env.get("HOME"), PARENT_ENV.HOME);
  for (const name of ALLOWED_ENV) if (PARENT_ENV[name] === undefined) assert.equal(env.has(name), false);
  const childSide = [stdin, args.join("\n"), [...env.values()].join("\n")].join("\n");
  for (const value of FAKE_SECRET_VALUES) assert.ok(!childSide.includes(value), "子へ秘匿値を渡さない");
  assert.ok(!childSide.includes(FAKE_TOKEN), "子へ鍵とトークンを渡さない");

  const cwd = (await readFile(join(fake.dir, "cwd"), "utf8")).trim();
  assert.ok(cwd.startsWith(join(fake.workRoot, "x-dev-rss-claude-")), "作業ディレクトリは置き場の下に作る");
  assert.deepEqual(await calls(fake), ["auth", "translate"]);
  await finish(fake, result, before);
});

test("翻訳の接続: 2 回目の試みは sonnet で訳し、認証の確かめは 1 回の実行で 1 回だけ（D4・D16）", async () => {
  const before = activeHandles();
  const fake = await makeFake(SUCCESS);
  const t = translator(fake);
  assert.equal((await t.translate("First post here.", 1)).ok, true);
  const second = await t.translate("First post here.", 2);
  assert.equal(second.ok, true);
  const args = (await readFile(join(fake.dir, "args"), "utf8")).split("\0");
  assert.equal(args[2], "sonnet");
  assert.deepEqual(await calls(fake), ["auth", "translate", "translate"]);
  await finish(fake, second, before);
});

const failures: [string, string, string][] = [
  ["0 でない終了コード", [READ_STDIN, emit(INIT, resultLine("訳文です。")), "exit 1"].join("\n"), "failed"],
  [
    "使用量の上限の形（is_error が true、終了コード 1。XPJA-7）",
    [READ_STDIN, emit(INIT, resultLine(`上限 ${FAKE_TOKEN}`, { is_error: true, subtype: "error_max_budget_usd" })), "exit 1"].join("\n"),
    "failed",
  ],
  ["is_error が true で subtype が success（偽の鍵の形）", [READ_STDIN, emit(INIT, resultLine("401", { is_error: true }))].join("\n"), "failed"],
  ["JSON でない出力", [READ_STDIN, `echo ${q(`not json ${FAKE_TOKEN}`)}`].join("\n"), "unavailable"],
  ["init の後に JSON でない行", [READ_STDIN, emit(INIT, `oops ${FAKE_TOKEN}`, resultLine("訳文です。"))].join("\n"), "failed"],
  ["結果の行が無い", [READ_STDIN, emit(INIT)].join("\n"), "failed"],
  ["result が空", [READ_STDIN, emit(INIT, resultLine("  "))].join("\n"), "failed"],
  [
    "init が API の鍵の経路を示す（D16 の (イ)）",
    [READ_STDIN, emit(JSON.stringify({ type: "system", subtype: "init", apiKeySource: "ANTHROPIC_API_KEY", tools: [], mcp_servers: [] }), resultLine("訳文です。"))].join("\n"),
    "unavailable",
  ],
  [
    "init に道具がある",
    [READ_STDIN, emit(JSON.stringify({ type: "system", subtype: "init", apiKeySource: "none", tools: ["Bash"], mcp_servers: [] }), resultLine("訳文です。"))].join("\n"),
    "unavailable",
  ],
  [
    "利用者の文脈の漏れ（架空のメールアドレスと system-reminder。D13 の (b)・(c)）",
    [READ_STDIN, emit(INIT, resultLine("<system-reminder>\nThe user's email address is nobody@example.com.\n</system-reminder>\n訳文です。"))].join("\n"),
    "failed",
  ],
  ["原文に無いメールアドレスの形（D13 の (c)）", [READ_STDIN, emit(INIT, resultLine("訳文です。nobody@example.com"))].join("\n"), "failed"],
  ["原文に無いタグの形（D13 の (d)）", [READ_STDIN, emit(INIT, resultLine("<env>訳文です。</env>"))].join("\n"), "failed"],
  ["原文での回数を超えた </post（D13 の (d)）", [READ_STDIN, emit(INIT, resultLine("訳文です。</post>"))].join("\n"), "failed"],
  ["原文に無い作業ディレクトリの接頭辞（D21）", [READ_STDIN, emit(INIT, resultLine("訳文です。x-dev-rss-claude-abc"))].join("\n"), "failed"],
  ["原文に無い /private/tmp（D21）", [READ_STDIN, emit(INIT, resultLine("訳文です。/private/tmp"))].join("\n"), "failed"],
  ["原文に無い HOME の値（D21）", [READ_STDIN, emit(INIT, resultLine(`訳文です。${PARENT_ENV.HOME ?? ""}`))].join("\n"), "failed"],
  ["原文に無い USER の値（D21）", [READ_STDIN, emit(INIT, resultLine(`訳文です。${PARENT_ENV.USER ?? ""}`))].join("\n"), "failed"],
];

for (const [name, body, reason] of failures) {
  test(`翻訳の接続: ${name} は失敗（${reason}）で、例外を出さない`, async () => {
    const before = activeHandles();
    const fake = await makeFake(body);
    const result = await translator(fake).translate("We're releasing a new model today.", 1);
    assert.deepEqual(result, { ok: false, reason });
    await finish(fake, result, before);
  });
}

test("翻訳の接続: 訳文に目印が漏れたら失敗（D13 の (a)）", async () => {
  const before = activeHandles();
  const body = [
    READ_STDIN,
    `m=$(head -n 1 "$D/stdin" | sed 's/^<post-//; s/>$//')`,
    emit(INIT),
    `printf '{"type":"result","subtype":"success","is_error":false,"result":"訳文 %s"}\\n' "$m"`,
  ].join("\n");
  const fake = await makeFake(body);
  const result = await translator(fake).translate("We're releasing a new model today.", 1);
  assert.deepEqual(result, { ok: false, reason: "failed" });
  await finish(fake, result, before);
});

test("翻訳の接続: 本文に </post> を含むポストの正しい訳は通る（D13）", async () => {
  const before = activeHandles();
  const fake = await makeFake([READ_STDIN, emit(INIT, resultLine("タグ </post> は閉じタグです。"))].join("\n"));
  const result = await translator(fake).translate("The tag </post> is a closing tag.", 1);
  assert.deepEqual(result, { ok: true, text: "タグ </post> は閉じタグです。" });
  await finish(fake, result, before);
});

test("翻訳の接続: 認証の確かめが契約のログインでなければ、訳の子を起動しない（D16 の (ア)・XPJA-7）", async () => {
  for (const authBody of [emit(JSON.stringify({ loggedIn: true, authMethod: "api_key", apiKeySource: "ANTHROPIC_API_KEY" })), emit("not json"), "exit 1"]) {
    const before = activeHandles();
    const fake = await makeFake(SUCCESS, authBody);
    const t = translator(fake);
    const first = await t.translate("We're releasing a new model today.", 1);
    const second = await t.translate("We're releasing a new model today.", 2);
    assert.deepEqual(first, { ok: false, reason: "unavailable" });
    assert.deepEqual(second, { ok: false, reason: "unavailable" });
    assert.deepEqual(await calls(fake), ["auth"]);
    await finish(fake, second, before);
  }
});

test("翻訳の接続: 置き場の親に CLAUDE.md か .claude があれば訳さない（D3）", async () => {
  for (const [where, name] of [["work", "CLAUDE.md"], ["", ".claude"]] as const) {
    const before = activeHandles();
    const fake = await makeFake(SUCCESS);
    await mkdir(join(fake.dir, where, name));
    const result = await translator(fake).translate("We're releasing a new model today.", 1);
    assert.deepEqual(result, { ok: false, reason: "unavailable" });
    assert.deepEqual(await calls(fake), []);
    await finish(fake, result, before);
  }
});

test("翻訳の接続: 待ち続ける子は時間切れで止める（D5・D14）", async () => {
  const before = activeHandles();
  const fake = await makeFake([READ_STDIN, emit(INIT), "sleep 30"].join("\n"));
  const result = await translator(fake, { timeoutMs: 3000 }).translate("We're releasing a new model today.", 1);
  assert.deepEqual(result, { ok: false, reason: "timeout" });
  await finish(fake, result, before);
});

test("翻訳の接続: TERM を無視する子は、猶予の後に KILL で止める（D14）", async () => {
  const before = activeHandles();
  const fake = await makeFake(["trap '' TERM", READ_STDIN, emit(INIT), "sleep 30"].join("\n"));
  const started = Date.now();
  const result = await translator(fake, { timeoutMs: 3000, graceMs: 300 }).translate("We're releasing a new model today.", 1);
  assert.deepEqual(result, { ok: false, reason: "timeout" });
  assert.ok(Date.now() - started < 10_000);
  await finish(fake, result, before);
});

test("翻訳の接続: 先頭のプロセスが標準出力を持った子孫を残して終わったら、子孫も止めて失敗にする（D14）", async () => {
  const before = activeHandles();
  const fake = await makeFake([READ_STDIN, "sleep 30 &", 'echo $! > "$D/descendant"', emit(INIT, resultLine("訳文です。")), "exit 0"].join("\n"));
  const result = await translator(fake).translate("We're releasing a new model today.", 1);
  assert.deepEqual(result, { ok: false, reason: "failed" });
  const descendant = (await readFile(join(fake.dir, "descendant"), "utf8")).trim();
  assert.throws(() => process.kill(Number(descendant), 0), { code: "ESRCH" });
  await finish(fake, result, before);
});

test("翻訳の接続: 出力が大きすぎれば止めて失敗にする", async () => {
  const before = activeHandles();
  const fake = await makeFake([READ_STDIN, emit(INIT), "yes aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"].join("\n"));
  const result = await translator(fake).translate("We're releasing a new model today.", 1);
  assert.deepEqual(result, { ok: false, reason: "failed" });
  await finish(fake, result, before);
});

test("翻訳の接続: パスが無い・実行できないときは起動できない失敗で、例外を出さない", async () => {
  const before = activeHandles();
  const fake = await makeFake(SUCCESS);
  const missing = await createClaudeTranslator({ claudePath: join(fake.dir, "none"), env: PARENT_ENV, workRoot: fake.workRoot }).translate("Hello there.", 1);
  assert.deepEqual(missing, { ok: false, reason: "unavailable" });
  await chmod(fake.claudePath, 0o644);
  const notExecutable = await translator(fake).translate("Hello there.", 1);
  assert.deepEqual(notExecutable, { ok: false, reason: "unavailable" });
  assert.deepEqual(await calls(fake), []);
  await finish(fake, notExecutable, before);
});

test("翻訳の接続: 標準入力を読まずにすぐ終わる子へ大きな本文を渡しても、例外を出さず失敗になる（EPIPE）", async () => {
  const before = activeHandles();
  const fake = await makeFake([emit(INIT, resultLine("訳文です。")), "exit 0"].join("\n"));
  const result = await translator(fake).translate("a".repeat(200_000), 1);
  assert.deepEqual(result, { ok: false, reason: "failed" });
  await finish(fake, result, before);
});

test("翻訳の接続: stopAll で起動中の訳の子が止まり、以後は子を起動せず unavailable を返す（D14）", async () => {
  const before = activeHandles();
  const fake = await makeFake([READ_STDIN, emit(INIT), "sleep 30"].join("\n"));
  const t = translator(fake, { timeoutMs: 60_000 });
  const pending = t.translate("We're releasing a new model today.", 1);
  await waitFile(join(fake.dir, "pid"));
  await t.stopAll();
  assert.deepEqual(await pending, { ok: false, reason: "unavailable" });
  const after = await t.translate("We're releasing a new model today.", 2);
  assert.deepEqual(after, { ok: false, reason: "unavailable" });
  assert.deepEqual(await calls(fake), ["auth", "translate"]);
  await finish(fake, after, before);
});

test("翻訳の接続: stopAll で認証の確かめの子も止まり、訳の子を起動しない（D14）", async () => {
  const before = activeHandles();
  const fake = await makeFake(SUCCESS, "sleep 30");
  const t = translator(fake, { timeoutMs: 60_000 });
  const pending = t.translate("We're releasing a new model today.", 1);
  await waitFile(join(fake.dir, "authpid"));
  await t.stopAll();
  assert.deepEqual(await pending, { ok: false, reason: "unavailable" });
  assert.deepEqual(await calls(fake), ["auth"]);
  await finish(fake, await pending, before);
});

test("翻訳の接続: stopAll の後は、認証の確かめも含めて子を 1 つも起動しない（D14）", async () => {
  const before = activeHandles();
  const fake = await makeFake(SUCCESS);
  const t = translator(fake);
  await t.stopAll();
  const result = await t.translate("We're releasing a new model today.", 1);
  assert.deepEqual(result, { ok: false, reason: "unavailable" });
  assert.deepEqual(await calls(fake), []);
  await finish(fake, result, before);
});

test("翻訳の接続: 訳文に子の作業ディレクトリ（cwd の値）が漏れたら失敗（D21）", async () => {
  const before = activeHandles();
  const body = [READ_STDIN, emit(INIT), `printf '{"type":"result","subtype":"success","is_error":false,"result":"訳文 %s"}\\n' "$(pwd -P)"`].join("\n");
  const fake = await makeFake(body);
  const result = await translator(fake).translate("We're releasing a new model today.", 1);
  assert.deepEqual(result, { ok: false, reason: "failed" });
  await finish(fake, result, before);
});

test("hasLeak（D21）: 子の環境に由来する文字列は、原文に無いときだけ漏れとし、空の値は見ない", () => {
  const marker = "0123456789abcdef0123456789abcdef";
  assert.equal(hasLeak("訳文 /private/tmp です。", "Path /private/tmp here.", marker, ["/private/tmp"]), false);
  assert.equal(hasLeak("訳文 /private/tmp です。", "No path here.", marker, ["/private/tmp"]), true);
  assert.equal(hasLeak("訳文です。", "No path here.", marker, [""]), false);
});

test("showsOverageEnabled（D21）: rate_limit_event の行のどこかに overageEnabled: true があれば当たる", () => {
  assert.equal(showsOverageEnabled(JSON.stringify({ type: "rate_limit_event", rate_limit_info: { overageEnabled: true } })), true);
  assert.equal(showsOverageEnabled(JSON.stringify({ type: "rate_limit_event", overageEnabled: true })), true);
  assert.equal(showsOverageEnabled(JSON.stringify({ type: "rate_limit_event", rate_limit_info: { overageEnabled: false } })), false);
  assert.equal(showsOverageEnabled(JSON.stringify({ type: "rate_limit_event", rate_limit_info: { overageEnabled: "true" } })), false);
  assert.equal(showsOverageEnabled(JSON.stringify({ type: "result", overageEnabled: true })), false);
  assert.equal(showsOverageEnabled("not json"), false);
});

const OVERAGE = JSON.stringify({ type: "rate_limit_event", rate_limit_info: { status: "allowed", overageEnabled: true } });

test("翻訳の接続: 使用量の知らせが上限を超えた分の支払いが有効と示したら unavailable で、以後は子を起動しない（D21）", async () => {
  const before = activeHandles();
  const fake = await makeFake([READ_STDIN, emit(INIT, resultLine("今日、新しいモデルをリリースします。"), OVERAGE)].join("\n"));
  const t = translator(fake);
  const first = await t.translate("We're releasing a new model today.", 1);
  assert.deepEqual(first, { ok: false, reason: "unavailable" });
  const second = await t.translate("We're releasing a new model today.", 2);
  assert.deepEqual(second, { ok: false, reason: "unavailable" });
  assert.deepEqual(await calls(fake), ["auth", "translate"]);
  await finish(fake, second, before);
});

test("翻訳の接続: 使用量の知らせが改行で終わらない最後の行でも、支払いが有効なら unavailable（D21）", async () => {
  const before = activeHandles();
  const fake = await makeFake([READ_STDIN, emit(INIT, resultLine("今日、新しいモデルをリリースします。")), `printf '%s' ${q(OVERAGE)}`].join("\n"));
  const result = await translator(fake).translate("We're releasing a new model today.", 1);
  assert.deepEqual(result, { ok: false, reason: "unavailable" });
  await finish(fake, result, before);
});

test("翻訳の接続: 使用量の知らせの後も出し続ける子は、知らせを見た時点で止める（D21）", async () => {
  const before = activeHandles();
  const fake = await makeFake([READ_STDIN, emit(INIT, OVERAGE), "sleep 30"].join("\n"));
  const started = Date.now();
  const result = await translator(fake, { timeoutMs: 60_000 }).translate("We're releasing a new model today.", 1);
  assert.deepEqual(result, { ok: false, reason: "unavailable" });
  assert.ok(Date.now() - started < 10_000);
  await finish(fake, result, before);
});

test("翻訳の接続: killAllNow は同期で TERM を無視する子のまとまりへ KILL を送り、以後は子を起動しない（D14）", async () => {
  const before = activeHandles();
  const fake = await makeFake(["trap '' TERM", READ_STDIN, emit(INIT), "sleep 30"].join("\n"));
  const t = translator(fake, { timeoutMs: 60_000, graceMs: 30_000 });
  const pending = t.translate("We're releasing a new model today.", 1);
  await waitFile(join(fake.dir, "pid"));
  const started = Date.now();
  t.killAllNow();
  assert.deepEqual(await pending, { ok: false, reason: "unavailable" });
  assert.ok(Date.now() - started < 5_000, "猶予を待たずに止まる");
  const after = await t.translate("We're releasing a new model today.", 2);
  assert.deepEqual(after, { ok: false, reason: "unavailable" });
  assert.deepEqual(await calls(fake), ["auth", "translate"]);
  // 起動中の子が無いときも例外を出さない
  t.killAllNow();
  await finish(fake, after, before);
});

test("hasLeak（D22）: 全角の＠や全角の英数字で表記を変えたメールアドレス・文脈の文字列・system-reminder も漏れとする", () => {
  const marker = "0123456789abcdef0123456789abcdef";
  const original = "We're releasing a new model today.";
  assert.equal(hasLeak("訳文です。nobody＠example.com", original, marker), true);
  assert.equal(hasLeak("訳文です。ｎｏｂｏｄｙ＠ｅｘａｍｐｌｅ．ｃｏｍ", original, marker), true);
  assert.equal(hasLeak("訳文です。＜ｓｙｓｔｅｍ－ｒｅｍｉｎｄｅｒ＞", original, marker), true);
  assert.equal(hasLeak("訳文です。／ｐｒｉｖａｔｅ／ｔｍｐ", original, marker, ["/private/tmp"]), true);
  assert.equal(hasLeak("訳文です。ｆａｋｅｕｓｅｒ", original, marker, ["fakeuser"]), true);
  // 原文にある全角の英数字は漏れとしない
  assert.equal(hasLeak("ＡＩ の訳文です。", "ＡＩ news today.", marker, ["fakeuser"]), false);
});

for (const [name, info] of [
  ["overageStatus が allowed", { status: "allowed", overageStatus: "allowed" }],
  ["overageStatus が allowed_warning", { status: "allowed", overageStatus: "allowed_warning" }],
  ["isUsingOverage が true", { status: "allowed", isUsingOverage: true }],
] as const) {
  test(`翻訳の接続: 使用量の知らせの ${name} なら unavailable で、以後は子を起動しない（D22）`, async () => {
    const before = activeHandles();
    const line = JSON.stringify({ type: "rate_limit_event", rate_limit_info: info });
    const fake = await makeFake([READ_STDIN, emit(INIT, resultLine("今日、新しいモデルをリリースします。"), line)].join("\n"));
    const t = translator(fake);
    assert.deepEqual(await t.translate("We're releasing a new model today.", 1), { ok: false, reason: "unavailable" });
    const second = await t.translate("We're releasing a new model today.", 2);
    assert.deepEqual(second, { ok: false, reason: "unavailable" });
    assert.deepEqual(await calls(fake), ["auth", "translate"]);
    await finish(fake, second, before);
  });
}

test("showsOverageEnabled（D22）: 支払いが無効の形（overageEnabled が false、overageStatus が rejected、isUsingOverage が false）は当たらない", () => {
  const line = JSON.stringify({ type: "rate_limit_event", rate_limit_info: { overageEnabled: false, overageStatus: "rejected", isUsingOverage: false } });
  assert.equal(showsOverageEnabled(line), false);
});

test("翻訳の接続: 先頭の子がパイプを閉じた子孫（TERM を無視する）を残して終わっても、子孫を止めてから結果を返す（D22）", async () => {
  const before = activeHandles();
  const body = [
    READ_STDIN,
    "( trap '' TERM; sleep 30 ) </dev/null >/dev/null 2>&1 &",
    'echo $! > "$D/descendant"',
    emit(INIT, resultLine("今日、新しいモデルをリリースします。")),
    "exit 0",
  ].join("\n");
  const fake = await makeFake(body);
  const result = await translator(fake, { graceMs: 300 }).translate("We're releasing a new model today.", 1);
  assert.deepEqual(result, { ok: true, text: "今日、新しいモデルをリリースします。" });
  const descendant = (await readFile(join(fake.dir, "descendant"), "utf8")).trim();
  assert.throws(() => process.kill(Number(descendant), 0), { code: "ESRCH" });
  await finish(fake, result, before);
});

test("翻訳の接続: 子孫を止めている間の killAllNow も、残った子孫のまとまりへ KILL を送る（D22）", async () => {
  const before = activeHandles();
  const body = [
    READ_STDIN,
    "( trap '' TERM; sleep 30 ) </dev/null >/dev/null 2>&1 &",
    'echo $! > "$D/descendant"',
    emit(INIT, resultLine("今日、新しいモデルをリリースします。")),
    "exit 0",
  ].join("\n");
  const fake = await makeFake(body);
  const t = translator(fake, { graceMs: 30_000 });
  const pending = t.translate("We're releasing a new model today.", 1);
  const descendant = await waitFile(join(fake.dir, "descendant"));
  // 先頭の子が終わり、子孫を止める段に入るのを待つ
  await delay(500);
  const started = Date.now();
  t.killAllNow();
  const result = await pending;
  assert.ok(Date.now() - started < 5_000, "猶予の 30 秒を待たない");
  assert.throws(() => process.kill(Number(descendant), 0), { code: "ESRCH" });
  await finish(fake, result, before);
});

test("翻訳の接続: 止める処理が始まった後に close の後の後始末に入ったら、SIGTERM の猶予を待たずに SIGKILL から始める（D23）", async () => {
  const before = activeHandles();
  const body = [READ_STDIN, "( trap '' TERM; sleep 30 ) </dev/null >/dev/null 2>&1 &", 'echo $! > "$D/descendant"', emit(INIT), "sleep 30"].join("\n");
  const fake = await makeFake(body);
  const t = translator(fake, { timeoutMs: 60_000, graceMs: 3000 });
  const pending = t.translate("We're releasing a new model today.", 1);
  const descendant = await waitFile(join(fake.dir, "descendant"));
  const started = Date.now();
  // 止める処理の SIGTERM で先頭の子が終わり、TERM を無視する子孫だけが残る
  await t.stopAll();
  assert.deepEqual(await pending, { ok: false, reason: "unavailable" });
  assert.ok(Date.now() - started < 2500, `猶予の 3 秒を重ねて待たない（${Date.now() - started} ミリ秒）`);
  assert.throws(() => process.kill(Number(descendant), 0), { code: "ESRCH" });
  await finish(fake, await pending, before);
});

test("翻訳の接続: stopAll は close の後に残ったまとまりの後始末が終わるまで待つ（D23）", async () => {
  const before = activeHandles();
  const body = [
    READ_STDIN,
    "( trap '' TERM; sleep 30 ) </dev/null >/dev/null 2>&1 &",
    'echo $! > "$D/descendant"',
    emit(INIT, resultLine("今日、新しいモデルをリリースします。")),
    "exit 0",
  ].join("\n");
  const fake = await makeFake(body);
  const t = translator(fake, { graceMs: 1000 });
  const pending = t.translate("We're releasing a new model today.", 1);
  const descendant = await waitFile(join(fake.dir, "descendant"));
  // 先頭の子が終わり、残ったまとまりの後始末（SIGTERM の猶予の待ち）に入るのを待つ
  await delay(300);
  await t.stopAll();
  // stopAll が戻った時点で、子孫は既に消えている
  assert.throws(() => process.kill(Number(descendant), 0), { code: "ESRCH" });
  await finish(fake, await pending, before);
});
