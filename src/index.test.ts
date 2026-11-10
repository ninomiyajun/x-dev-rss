// 入口の試験。子のプロセスで動かす。X と Slack へは通信しない（通信する部品は偽の fetch に差し替えるか、通信の前で止まる場面だけを使う）。
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readdir, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { containsSecret, fakeSecretsText, FAKE_SECRETS } from "./app/fakes.ts";
import { defaultOptions, parseArgs } from "./index.ts";

const entry = fileURLToPath(new URL("./index.ts", import.meta.url));
const entryUrl = new URL("./index.ts", import.meta.url).href;
const fakesUrl = new URL("./app/fakes.ts", import.meta.url).href;

type Run = { status: number | null; stdout: string; stderr: string };

async function sandbox(): Promise<{ dir: string; env: NodeJS.ProcessEnv }> {
  const dir = await mkdtemp(join(tmpdir(), "x-dev-rss-test-"));
  // 子のプロセスのホームを一時ディレクトリにする（所有者の本物の秘匿値と記録に触れない）。
  const env: NodeJS.ProcessEnv = { PATH: process.env.PATH, HOME: dir, XDG_STATE_HOME: join(dir, "state-home") };
  return { dir, env };
}

function node(args: string[], env: NodeJS.ProcessEnv, input?: string): Run {
  const r = spawnSync(process.execPath, args, { env, encoding: "utf8", timeout: 60000, input });
  return { status: r.status, stdout: r.stdout, stderr: r.stderr };
}

async function setup(secretsText: string) {
  const { dir, env } = await sandbox();
  const secrets = join(dir, "secrets.env");
  await writeFile(secrets, secretsText, { mode: 0o600 });
  const config = join(dir, "accounts.json");
  await writeFile(config, '{"accounts": ["AnthropicAI"]}');
  const state = join(dir, "state");
  return { dir, env, secrets, config, state };
}

test("引数: 既定の値と、知らない引数", () => {
  const d = defaultOptions({ XDG_STATE_HOME: "/xdg" });
  assert.equal(d.stateDir, join("/xdg", "x-dev-rss"));
  assert.ok(d.config.endsWith(join("config", "accounts.json")));
  assert.ok(d.secrets.endsWith(join(".config", "x-dev-rss", "secrets.env")));
  assert.deepEqual(parseArgs(["--dry-run", "--state-dir", "s"], {})?.stateDir, "s");
  assert.equal(parseArgs(["--state-dir"], {}), undefined);
  assert.equal(parseArgs(["--nope"], {}), undefined);
});

test("知らない引数は使い方の 1 行を出して終了コード 2", async () => {
  const { dir, env } = await sandbox();
  const r = node([entry, "--nope"], env);
  assert.equal(r.status, 2);
  assert.match(r.stdout, /^使い方: node src\/index.ts/);
  await rm(dir, { recursive: true });
});

test("XPOST-9 / XPOST-10: X_CT0 が無ければ、その名前の 1 行で終了コード 1。ほかの値は出さず、記録も作らない", async () => {
  const s = await setup(fakeSecretsText({ X_CT0: null }));
  const r = node([entry, "--secrets", s.secrets, "--state-dir", s.state, "--config", s.config], s.env);
  assert.equal(r.status, 1);
  assert.equal(r.stdout, "秘匿値が足りません: X_CT0\n");
  assert.ok(!containsSecret(r.stdout + r.stderr));
  assert.ok(!(await readdir(s.dir)).includes("state"));
  await rm(s.dir, { recursive: true });
});

test("XPOST-9: 秘匿値のファイルが無いか、値が空なら、足りない名前を挙げる", async () => {
  const s = await setup(fakeSecretsText({ X_AUTH_TOKEN: "" }));
  const empty = node([entry, "--secrets", s.secrets, "--state-dir", s.state, "--config", s.config], s.env);
  assert.equal(empty.stdout, "秘匿値が足りません: X_AUTH_TOKEN\n");
  const none = node([entry, "--secrets", join(s.dir, "none.env"), "--state-dir", s.state, "--config", s.config], s.env);
  assert.equal(none.status, 1);
  assert.equal(none.stdout, "秘匿値が足りません: X_USERNAME、X_AUTH_TOKEN、X_CT0、SLACK_WEBHOOK_URL\n");
  await rm(s.dir, { recursive: true });
});

test("V5: 形の崩れた Webhook の URL では、変数の名前だけの 1 行を出して終了コード 1", async () => {
  for (const bad of ["http://hooks.slack.com/services/example-fake", "https://hooks.slack.com/services/a b", "not-a-url-fake"]) {
    const s = await setup(fakeSecretsText({ SLACK_WEBHOOK_URL: bad }));
    const r = node([entry, "--secrets", s.secrets, "--state-dir", s.state, "--config", s.config], s.env);
    assert.equal(r.status, 1, bad);
    assert.equal(r.stdout, "秘匿値の形が違います: SLACK_WEBHOOK_URL\n");
    assert.ok(!r.stdout.includes(bad.split("/").pop() ?? bad));
    await rm(s.dir, { recursive: true });
  }
});

test("XPOST-10 / D13: DEBUG=* でもライブラリの記録は出ず、401 の応答の set-cookie の値も出ない", async () => {
  const s = await setup(fakeSecretsText());
  const script = `
    import { main } from ${JSON.stringify(entryUrl)};
    import { FAKE_SECRETS } from ${JSON.stringify(fakesUrl)};
    const fakeFetch = async () => new Response(JSON.stringify({ errors: [{ message: FAKE_SECRETS.X_CT0 }] }), {
      status: 401,
      headers: { "content-type": "application/json", "set-cookie": "auth_token=" + FAKE_SECRETS.X_AUTH_TOKEN },
    });
    const code = await main(process.argv.slice(1), process.env, { fetch: fakeFetch, sleep: async () => {} });
    process.exitCode = code;
  `;
  const r = node(
    ["--input-type=module", "-e", script, "--", "--secrets", s.secrets, "--state-dir", s.state, "--config", s.config],
    { ...s.env, DEBUG: "*" },
  );
  assert.equal(r.status, 1, r.stderr);
  const all = r.stdout + r.stderr;
  assert.ok(!all.includes("twitter-scraper"), all);
  assert.ok(!containsSecret(all), all);
  const lines = r.stdout.trim().split("\n");
  assert.equal(lines[0], "環境変数 DEBUG を消してから動かしました");
  assert.ok(lines.includes("X からの取得に失敗しました: @AnthropicAI（取得用のアカウントのログインが拒まれました）"), all);
  assert.equal(r.stderr, "");
  // 記録のディレクトリのファイルにも値が入らない（ロックは外されている）
  for (const name of await readdir(s.state)) assert.notEqual(name, "run.lock");
  await rm(s.dir, { recursive: true });
});

test("XPOST-10 / D13: 実行の途中の想定外の例外は、決まった 1 行だけで終了コード 1", async () => {
  const s = await setup(fakeSecretsText());
  // 記録のディレクトリの場所にファイルを置き、ロックを取る段で想定外の失敗を起こす
  await writeFile(s.state, FAKE_SECRETS.X_AUTH_TOKEN);
  const r = node([entry, "--secrets", s.secrets, "--state-dir", s.state, "--config", s.config], s.env);
  assert.equal(r.status, 1);
  assert.equal(r.stdout, "想定外の失敗で止まりました\n");
  assert.equal(r.stderr, "");
  await rm(s.dir, { recursive: true });
});

for (const kind of ["unhandledRejection", "uncaughtException"] as const) {
  test(`XPOST-10 / D13: 受け止められていない失敗（${kind}）は、決まった 1 行だけで終了コード 1`, async () => {
    const { dir, env } = await sandbox();
    const trigger =
      kind === "unhandledRejection"
        ? "Promise.reject(new Error(FAKE_SECRETS.X_CT0));"
        : "setTimeout(() => { throw new Error(FAKE_SECRETS.SLACK_WEBHOOK_URL); }, 0);";
    const script = `
      import { installCrashHandlers } from ${JSON.stringify(entryUrl)};
      import { FAKE_SECRETS } from ${JSON.stringify(fakesUrl)};
      installCrashHandlers();
      ${trigger}
    `;
    const r = node(["--input-type=module", "-e", script], env);
    assert.equal(r.status, 1);
    assert.equal(r.stdout, "");
    assert.equal(r.stderr, "想定外の失敗で止まりました\n");
    await rm(dir, { recursive: true });
  });
}

test("V7: NODE_DEBUG が空でなければ、秘匿値を読む前に決まった 1 行で終了コード 1", async () => {
  const s = await setup(fakeSecretsText());
  for (const value of ["fetch", "undici"]) {
    const r = node([entry, "--secrets", s.secrets, "--state-dir", s.state, "--config", s.config], { ...s.env, NODE_DEBUG: value });
    assert.equal(r.status, 1, value);
    assert.equal(r.stdout, "環境変数 NODE_DEBUG が設定されているため止めました（送り先が出力に出るおそれがあるため、外してから実行してください）\n");
    assert.ok(!containsSecret(r.stdout + r.stderr));
  }
  assert.ok(!(await readdir(s.dir)).includes("state"));
  await rm(s.dir, { recursive: true });
});

test("V7: 秘匿値のファイルが所有者以外にも読めるときと、読めないときは、それぞれの 1 行で終了コード 1", async () => {
  const s = await setup(fakeSecretsText());
  await chmod(s.secrets, 0o644);
  const insecure = node([entry, "--secrets", s.secrets, "--state-dir", s.state, "--config", s.config], s.env);
  assert.equal(insecure.status, 1);
  assert.equal(insecure.stdout, "秘匿値のファイルが所有者以外にも読める権限になっているため止めました（権限を 600 にしてください）\n");
  await chmod(s.secrets, 0o000);
  const unreadable = node([entry, "--secrets", s.secrets, "--state-dir", s.state, "--config", s.config], s.env);
  assert.equal(unreadable.status, 1);
  assert.equal(unreadable.stdout, "秘匿値のファイルを読めないため止めました（ファイルの権限を確かめてください）\n");
  await chmod(s.secrets, 0o600);
  await rm(s.dir, { recursive: true });
});

test("V7: XDG_STATE_HOME が絶対パスでなければ無視して既定の場所を使う", () => {
  const d = defaultOptions({ XDG_STATE_HOME: "relative/state" });
  assert.ok(d.stateDir.endsWith(join(".local", "state", "x-dev-rss")));
  assert.ok(!d.stateDir.includes("relative"));
});

// ---- 翻訳の引数と終了要求（計画の手順 7） ----

const EN = "We're releasing a new model today.";
const JA = "本日、新しいモデルを公開します。";
const INIT = JSON.stringify({ type: "system", subtype: "init", apiKeySource: "none", tools: [], mcp_servers: [] });
const AUTH_OK = JSON.stringify({ loggedIn: true, authMethod: "claude.ai" });

function q(text: string): string {
  return `'${text.replace(/'/g, `'\\''`)}'`;
}

/** 偽物の claude を作る。auth status には契約のログインを返し、訳の呼び出しでは番号を書いてから body を動かす。 */
async function fakeClaude(dir: string, body: string): Promise<{ claudePath: string; workRoot: string; pidFile: string }> {
  const workRoot = join(dir, "work");
  await mkdir(workRoot);
  const claudePath = join(dir, "claude");
  const pidFile = join(dir, "pid");
  const script = [
    "#!/bin/sh",
    `if [ "$1" = auth ]; then printf '%s\\n' ${q(AUTH_OK)}; exit 0; fi`,
    `echo $$ > ${q(pidFile)}`,
    "cat > /dev/null",
    `printf '%s\\n' ${q(INIT)}`,
    body,
    "",
  ].join("\n");
  await writeFile(claudePath, script, { mode: 0o755 });
  return { claudePath, workRoot, pidFile };
}

/** 入口の main を、翻訳の作業ディレクトリの置き場と待ちを差し替えて動かす -e のスクリプト。 */
function tryScript(workRoot: string): string {
  return `
    import { main } from ${JSON.stringify(entryUrl)};
    const code = await main(process.argv.slice(1), process.env, { sleep: async () => {}, claudeWorkRoot: ${JSON.stringify(workRoot)} });
    process.exitCode = code;
  `;
}

test("D2: --claude が絶対パスでなければ、使い方の 1 行で終了コード 2", async () => {
  const { dir, env } = await sandbox();
  for (const args of [["--claude", "claude"], ["--claude", "./bin/claude"], ["--try-translate", "--claude", "claude"]]) {
    const r = node([entry, ...args], env, "");
    assert.equal(r.status, 2, args.join(" "));
    assert.match(r.stdout, /^使い方: node src\/index.ts/);
  }
  assert.equal(parseArgs([], {})?.claude, "/opt/homebrew/bin/claude");
  assert.equal(parseArgs(["--claude", "/usr/bin/false"], {})?.claude, "/usr/bin/false");
  await rm(dir, { recursive: true });
});

test("D17: --show-text は --dry-run と一緒のときだけ受け付け、それ以外は使い方の 1 行で終了コード 2", async () => {
  const { dir, env } = await sandbox();
  const r = node([entry, "--show-text"], env);
  assert.equal(r.status, 2);
  assert.match(r.stdout, /^使い方: node src\/index.ts/);
  assert.equal(parseArgs(["--dry-run", "--show-text"], {})?.showText, true);
  assert.equal(parseArgs(["--show-text", "--dry-run"], {})?.showText, true);
  // --try-translate と --dry-run は一緒に使えない
  assert.equal(parseArgs(["--try-translate", "--dry-run"], {}), undefined);
  await rm(dir, { recursive: true });
});

test("D7: --try-translate は、偽物の claude の訳を、訳した → 本文 → 機械翻訳の印 → 所要時間の順に出して終了コード 0", async () => {
  const { dir, env } = await sandbox();
  const fake = await fakeClaude(dir, `printf '%s\\n' ${q(JSON.stringify({ type: "result", subtype: "success", is_error: false, result: JA }))}`);
  const r = node(["--input-type=module", "-e", tryScript(fake.workRoot), "--", "--try-translate", "--claude", fake.claudePath], env, EN);
  assert.equal(r.status, 0, r.stderr);
  const lines = r.stdout.trimEnd().split("\n");
  assert.deepEqual(lines.slice(0, 3), ["訳した", JA, "（機械翻訳）"]);
  assert.match(lines[3] ?? "", /^所要時間: \d+\.\d 秒$/);
  assert.equal(lines.length, 4);
  // 作業ディレクトリは消えている
  assert.deepEqual(await readdir(fake.workRoot), []);
  await rm(dir, { recursive: true });
});

test("D7: --try-translate に日本語の文を渡すと、claude を呼ばずに、訳さなかった → 原文と同じ本文 → 所要時間", async () => {
  const { dir, env } = await sandbox();
  const fake = await fakeClaude(dir, "exit 1");
  const r = node(["--input-type=module", "-e", tryScript(fake.workRoot), "--", "--try-translate", "--claude", fake.claudePath], env, JA);
  assert.equal(r.status, 0, r.stderr);
  const lines = r.stdout.trimEnd().split("\n");
  assert.deepEqual(lines.slice(0, 2), ["訳さなかった", JA]);
  assert.match(lines[2] ?? "", /^所要時間: /);
  assert.equal(lines.length, 3);
  await assert.rejects(readFile(fake.pidFile));
  await rm(dir, { recursive: true });
});

test("D7 / XPJA-3: --try-translate で翻訳に失敗したら（--claude /usr/bin/false）、翻訳に失敗した → 原文 → 失敗の印。終了コード 0", async () => {
  const { dir, env } = await sandbox();
  const workRoot = join(dir, "work");
  await mkdir(workRoot);
  const r = node(["--input-type=module", "-e", tryScript(workRoot), "--", "--try-translate", "--claude", "/usr/bin/false"], env, EN);
  assert.equal(r.status, 0, r.stderr);
  const lines = r.stdout.trimEnd().split("\n");
  assert.deepEqual(lines.slice(0, 3), ["翻訳に失敗した", EN, "（翻訳に失敗したため原文のまま）"]);
  assert.match(lines[3] ?? "", /^所要時間: /);
  assert.equal(r.stderr, "");
  await rm(dir, { recursive: true });
});

test("D7: --try-translate の本文が 100,000 文字を超えたら、超過の行で終了コード 2", async () => {
  const { dir, env } = await sandbox();
  const r = node([entry, "--try-translate", "--claude", "/usr/bin/false"], env, "a".repeat(100_001));
  assert.equal(r.status, 2);
  assert.equal(r.stdout, "本文が長すぎるため訳しませんでした（100000 文字まで）\n");
  await rm(dir, { recursive: true });
});

test("D14: 訳の途中で SIGTERM を受けると、偽物の子を止め、投稿せず、ロックを外し、中断の 1 行を出して終了コード 143", async () => {
  const s = await setup(fakeSecretsText());
  const dir = await realpath(s.dir);
  const fake = await fakeClaude(dir, "sleep 30");
  const script = `
    import { main } from ${JSON.stringify(entryUrl)};
    import { FakeFetcher, fakePost, fetched } from ${JSON.stringify(fakesUrl)};
    const fetcher = new FakeFetcher({ AnthropicAI: fetched([fakePost(1, { text: ${JSON.stringify(EN)} })]) });
    let slackCalls = 0;
    const fakeFetch = async () => { slackCalls++; return new Response("ok"); };
    const code = await main(process.argv.slice(1), process.env, {
      fetcher, fetch: fakeFetch, sleep: async () => {}, claudeWorkRoot: ${JSON.stringify(fake.workRoot)}, claudeGraceMs: 500,
    });
    console.log("slack-calls=" + slackCalls);
    process.exitCode = code;
  `;
  const child = spawn(
    process.execPath,
    ["--input-type=module", "-e", script, "--", "--secrets", s.secrets, "--state-dir", s.state, "--config", s.config, "--claude", fake.claudePath],
    { env: s.env, stdio: ["ignore", "pipe", "pipe"] },
  );
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (c: Buffer) => (stdout += c.toString("utf8")));
  child.stderr.on("data", (c: Buffer) => (stderr += c.toString("utf8")));
  const exited = new Promise<number | null>((done) => child.on("close", (code) => done(code)));
  // 偽物の子が起動するまで待つ（回数の決まった待ち）
  let pid = "";
  for (let i = 0; i < 300 && pid === ""; i++) {
    pid = ((await readFile(fake.pidFile, "utf8").catch(() => "")) as string).trim();
    if (pid === "") await delay(50);
  }
  assert.notEqual(pid, "", "偽物の子が起動しなかった");
  assert.ok((await readdir(s.state)).includes("run.lock"));
  child.kill("SIGTERM");
  const code = await exited;
  assert.equal(code, 143, stdout + stderr);
  assert.deepEqual(stdout.trimEnd().split("\n"), ["中断の要求を受けたため止めました", "slack-calls=0"]);
  assert.equal(stderr, "");
  // 偽物の子のまとまりに生きたプロセスが残っていない
  assert.throws(() => process.kill(-Number(pid), 0), (err: NodeJS.ErrnoException) => err.code === "ESRCH");
  // ロックが外れ、記録に投稿していないポストが入っていない
  assert.ok(!(await readdir(s.state)).includes("run.lock"));
  const record = JSON.parse(await readFile(join(s.state, "notified.json"), "utf8")) as { accounts: Record<string, { ids: string[] }> };
  assert.deepEqual(Object.values(record.accounts).flatMap((a) => a.ids), []);
  assert.ok(!containsSecret(stdout + stderr));
  await rm(s.dir, { recursive: true });
});

test("D14: 2 回目の SIGTERM では待たずに終わり、終わる前に TERM を無視する偽物の子のまとまりへ KILL を送る", async () => {
  const s = await setup(fakeSecretsText());
  const dir = await realpath(s.dir);
  const fake = await fakeClaude(dir, "trap '' TERM\nsleep 30");
  const script = `
    import { main } from ${JSON.stringify(entryUrl)};
    import { FakeFetcher, fakePost, fetched } from ${JSON.stringify(fakesUrl)};
    const fetcher = new FakeFetcher({ AnthropicAI: fetched([fakePost(1, { text: ${JSON.stringify(EN)} })]) });
    const fakeFetch = async () => new Response("ok");
    const code = await main(process.argv.slice(1), process.env, {
      fetcher, fetch: fakeFetch, sleep: async () => {}, claudeWorkRoot: ${JSON.stringify(fake.workRoot)}, claudeGraceMs: 30000,
    });
    process.exitCode = code;
  `;
  const child = spawn(
    process.execPath,
    ["--input-type=module", "-e", script, "--", "--secrets", s.secrets, "--state-dir", s.state, "--config", s.config, "--claude", fake.claudePath],
    { env: s.env, stdio: ["ignore", "pipe", "pipe"] },
  );
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (c: Buffer) => (stdout += c.toString("utf8")));
  child.stderr.on("data", (c: Buffer) => (stderr += c.toString("utf8")));
  const exited = new Promise<number | null>((done) => child.on("close", (code) => done(code)));
  let pid = "";
  for (let i = 0; i < 300 && pid === ""; i++) {
    pid = ((await readFile(fake.pidFile, "utf8").catch(() => "")) as string).trim();
    if (pid === "") await delay(50);
  }
  assert.notEqual(pid, "", "偽物の子が起動しなかった");
  child.kill("SIGTERM");
  // 1 回目の終了要求の処理が始まるのを待ってから、2 回目を送る
  await delay(500);
  const started = Date.now();
  child.kill("SIGTERM");
  const code = await exited;
  assert.equal(code, 143, stdout + stderr);
  assert.ok(Date.now() - started < 10_000, "猶予の 30 秒を待たずに終わる");
  // 偽物の子のまとまりに生きたプロセスが残っていない（KILL の届くのを回数の決まった待ちで確かめる）
  let gone = false;
  for (let i = 0; i < 100 && !gone; i++) {
    try {
      process.kill(-Number(pid), 0);
      await delay(20);
    } catch (err) {
      gone = (err as NodeJS.ErrnoException).code === "ESRCH";
    }
  }
  assert.ok(gone, "偽物の子のまとまりが残っていない");
  assert.ok(!containsSecret(stdout + stderr));
  await rm(s.dir, { recursive: true, force: true });
});
