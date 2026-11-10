// 入口の試験。子のプロセスで動かす。X と Slack へは通信しない（通信する部品は偽の fetch に差し替えるか、通信の前で止まる場面だけを使う）。
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmod, mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
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

function node(args: string[], env: NodeJS.ProcessEnv): Run {
  const r = spawnSync(process.execPath, args, { env, encoding: "utf8", timeout: 60000 });
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
