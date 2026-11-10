// ファイルを扱う外との接続（秘匿値・設定・記録・ロック）の試験。一時ディレクトリだけを使う。
import { test } from "node:test";
import assert from "node:assert/strict";
import { chmod, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createSecretsFile, openBundle, parseSecretsText } from "./secrets.ts";
import { createConfigFile, parseAccountsConfig } from "./config.ts";
import { createRecordFile, RECORD_FILE_NAME } from "./record-file.ts";
import { createLockFile, LOCK_FILE_NAME } from "./lock-file.ts";
import { FAKE_SECRETS, fakeSecretsText } from "../app/fakes.ts";

async function tempDir(): Promise<string> {
  return mkdtemp(join(tmpdir(), "x-dev-rss-test-"));
}

test("秘匿値: 4 つ揃えば束を返し、束そのものには値が入らない", () => {
  const result = parseSecretsText(`# 注釈\n\n${fakeSecretsText()}`);
  assert.ok(result.ok);
  if (!result.ok) return;
  assert.equal(JSON.stringify(result.bundle), "{}");
  assert.deepEqual(openBundle(result.bundle), {
    username: FAKE_SECRETS.X_USERNAME,
    authToken: FAKE_SECRETS.X_AUTH_TOKEN,
    ct0: FAKE_SECRETS.X_CT0,
    webhookUrl: FAKE_SECRETS.SLACK_WEBHOOK_URL,
  });
});

test("秘匿値: 引用符を外し、シェルの展開はしない", () => {
  const text = fakeSecretsText({ X_USERNAME: `"$HOME_value"` });
  const result = parseSecretsText(text);
  assert.ok(result.ok);
  if (result.ok) assert.equal(openBundle(result.bundle).username, "$HOME_value");
});

test("XPOST-9: 足りない変数と空の変数の名前を返し、値は返さない", () => {
  const result = parseSecretsText(fakeSecretsText({ X_CT0: null, X_USERNAME: "" }));
  assert.deepEqual(result, { ok: false, reason: "missing", missing: ["X_USERNAME", "X_CT0"], malformed: [] });
});

test("XPOST-9: ファイルが無いときは 4 つとも足りない", async () => {
  const dir = await tempDir();
  const result = await createSecretsFile(join(dir, "none.env")).load();
  assert.deepEqual(result, { ok: false, reason: "missing", missing: ["X_USERNAME", "X_AUTH_TOKEN", "X_CT0", "SLACK_WEBHOOK_URL"], malformed: [] });
  await rm(dir, { recursive: true });
});

test("XPOST-9: Cookie の値に英数字と % _ - 以外が混ざれば形の違う変数として返し、値は返さない", () => {
  for (const bad of ["a;b", "a b", "a=b", "a,b", 'a"b']) {
    const text = fakeSecretsText({ X_AUTH_TOKEN: bad, X_CT0: `${bad}c` });
    const result = parseSecretsText(text);
    assert.equal(result.ok, false);
    if (result.ok || result.reason !== "missing") return;
    assert.deepEqual([...result.malformed].sort(), ["X_AUTH_TOKEN", "X_CT0"]);
    assert.ok(!JSON.stringify(result).includes(bad));
  }
  assert.equal(parseSecretsText(fakeSecretsText({ X_AUTH_TOKEN: "Ab9%_-", X_CT0: "z-Z_0%" })).ok, true);
});

test("V5: 形の崩れた Webhook の URL は形の違う変数として返す", () => {
  for (const bad of ["http://hooks.slack.com/services/example", "https://hooks.slack.com/services/a b", "not-a-url"]) {
    const result = parseSecretsText(fakeSecretsText({ SLACK_WEBHOOK_URL: bad }));
    assert.deepEqual(result, { ok: false, reason: "missing", missing: [], malformed: ["SLACK_WEBHOOK_URL"] }, bad);
  }
});

test("設定: @ を外し、大文字小文字を区別せずに重複を除く", () => {
  assert.deepEqual(parseAccountsConfig('{"accounts": ["@AnthropicAI", "anthropicai", "Q_1"]}'), {
    ok: true,
    accounts: ["AnthropicAI", "Q_1"],
  });
});

test("XPOST-15: 設定が無い・空・読めない・形が違うときは読めない", async () => {
  assert.deepEqual(parseAccountsConfig('{"accounts": []}'), { ok: false });
  assert.deepEqual(parseAccountsConfig("{"), { ok: false });
  assert.deepEqual(parseAccountsConfig('{"accounts": ["bad name"]}'), { ok: false });
  assert.deepEqual(parseAccountsConfig("[]"), { ok: false });
  const dir = await tempDir();
  assert.deepEqual(await createConfigFile(join(dir, "none.json")).read(), { ok: false });
  await rm(dir, { recursive: true });
});

test("記録: 無いときは空、書き込むとディレクトリは 700・ファイルは 600 で、読み直せる", async () => {
  const base = await tempDir();
  const dir = join(base, "state");
  const rec = createRecordFile(dir);
  const first = await rec.read();
  assert.ok(first.ok && first.accounts.size === 0);
  await rec.add("AnthropicAI", []);
  await rec.add("AnthropicAI", ["2", "1"]);
  assert.equal((await stat(dir)).mode & 0o777, 0o700);
  assert.equal((await stat(join(dir, RECORD_FILE_NAME))).mode & 0o777, 0o600);
  const again = await createRecordFile(dir).read();
  assert.ok(again.ok);
  if (again.ok) assert.deepEqual([...(again.accounts.get("anthropicai") ?? [])], ["2", "1"]);
  // 一時ファイルが残らない
  assert.deepEqual(await readdir(dir), [RECORD_FILE_NAME]);
  await rm(base, { recursive: true });
});

test("XPOST-13: 壊れた記録は読めない扱いで、書き込もうとしても上書きしない", async () => {
  const dir = await tempDir();
  const path = join(dir, RECORD_FILE_NAME);
  for (const broken of ['{"version": 1, "accounts": {"Ab": {"ids": []}, "aB": {"ids": ["1"]}}}', "{not json", '{"version": 2, "accounts": {}}', '{"version": 1, "accounts": {"a": {"ids": ["12x"]}}}']) {
    await writeFile(path, broken);
    const rec = createRecordFile(dir);
    assert.deepEqual(await rec.read(), { ok: false }, broken);
    await assert.rejects(rec.add("a", ["1"]));
    assert.equal(await readFile(path, "utf8"), broken);
  }
  await rm(dir, { recursive: true });
});


test("V7: 秘匿値のファイルが所有者以外にも読める権限なら、中身を読まずに止める", async () => {
  const dir = await tempDir();
  const path = join(dir, "secrets.env");
  await writeFile(path, fakeSecretsText(), { mode: 0o600 });
  assert.equal((await createSecretsFile(path).load()).ok, true);
  for (const mode of [0o644, 0o640, 0o604, 0o610, 0o601, 0o620, 0o602]) {
    await chmod(path, mode);
    assert.deepEqual(await createSecretsFile(path).load(), { ok: false, reason: "insecure" }, mode.toString(8));
  }
  await rm(dir, { recursive: true });
});

test("V7: 秘匿値のファイルの持ち主が実行している利用者と違えば、中身を読まずに止める", async () => {
  const dir = await tempDir();
  const path = join(dir, "secrets.env");
  await writeFile(path, fakeSecretsText(), { mode: 0o600 });
  const owner = (await stat(path)).uid;
  assert.equal((await createSecretsFile(path, { uid: owner }).load()).ok, true);
  assert.deepEqual(await createSecretsFile(path, { uid: owner + 1 }).load(), { ok: false, reason: "foreign-owner" });
  // 権限の問題が先に分かれば、そちらを返す。
  await chmod(path, 0o640);
  assert.deepEqual(await createSecretsFile(path, { uid: owner + 1 }).load(), { ok: false, reason: "insecure" });
  await rm(dir, { recursive: true });
});

test("V7: 秘匿値のファイルがあるのに読めないときは、無いときと別の結果", async () => {
  const dir = await tempDir();
  const path = join(dir, "secrets.env");
  await writeFile(path, fakeSecretsText(), { mode: 0o600 });
  await chmod(path, 0o000);
  assert.deepEqual(await createSecretsFile(path).load(), { ok: false, reason: "unreadable" });
  await chmod(path, 0o600);
  await rm(dir, { recursive: true });
});

test("V8: 記録の名前の変更に失敗したら、一時ファイルを残さずに例外になり、前の記録は変わらない", async () => {
  const dir = await tempDir();
  const ok = createRecordFile(dir);
  await ok.read();
  await ok.add("a", ["1"]);
  const before = await readFile(join(dir, RECORD_FILE_NAME), "utf8");
  const failing = createRecordFile(dir, {
    rename: async () => {
      throw Object.assign(new Error("rename failed"), { code: "EIO" });
    },
  });
  await failing.read();
  await assert.rejects(failing.add("a", ["2"]));
  assert.deepEqual(await readdir(dir), [RECORD_FILE_NAME]);
  assert.equal(await readFile(join(dir, RECORD_FILE_NAME), "utf8"), before);
  await rm(dir, { recursive: true });
});

// ---- ロック（D9） ----

test("記録: 書き込みに失敗した ID は手元にも残らず、次に書けたときにも混ざらない", async () => {
  const dir = await tempDir();
  let failNext = false;
  const record = createRecordFile(dir, {
    rename: async (from, to) => {
      if (failNext) {
        failNext = false;
        throw Object.assign(new Error("rename failed"), { code: "EIO" });
      }
      const { rename } = await import("node:fs/promises");
      await rename(from, to);
    },
  });
  await record.read();
  await record.add("a", ["1"]);
  failNext = true;
  await assert.rejects(record.add("a", ["2"]));
  await record.add("a", ["3"]);
  const saved = JSON.parse(await readFile(join(dir, RECORD_FILE_NAME), "utf8"));
  assert.deepEqual([...saved.accounts.a.ids].sort(), ["1", "3"]);
  const reread = await createRecordFile(dir).read();
  assert.ok(reread.ok && !reread.accounts.get("a")?.has("2"));
  await rm(dir, { recursive: true });
});

function errno(code: string): Error {
  return Object.assign(new Error(code), { code });
}

/** 生きているプロセスの番号と開始時刻の表で動く、偽物の kill と startTimeOf。 */
function processTable(alive: Record<number, string>) {
  return {
    kill: (pid: number) => {
      if (!(pid in alive)) throw errno("ESRCH");
    },
    startTimeOf: async (pid: number) => alive[pid],
  };
}

test("D9: プロセスの開始時刻は、ロケールと時間帯の違う実行から読んでも同じ文字列になる", () => {
  const module = fileURLToPath(new URL("./lock-file.ts", import.meta.url));
  const script = `const { psStartTime } = await import(${JSON.stringify(module)}); console.log(await psStartTime(${process.pid}));`;
  const read = (extra: Record<string, string>) =>
    spawnSync(process.execPath, ["--input-type=module", "-e", script], {
      env: { PATH: process.env.PATH ?? "/usr/bin:/bin", ...extra },
      encoding: "utf8",
      timeout: 30000,
    }).stdout.trim();
  const a = read({ LANG: "ja_JP.UTF-8", LC_ALL: "ja_JP.UTF-8", TZ: "Asia/Tokyo" });
  const b = read({ LANG: "fr_FR.UTF-8", LC_TIME: "fr_FR.UTF-8", TZ: "America/New_York" });
  assert.notEqual(a, "");
  assert.notEqual(a, "undefined");
  assert.equal(a, b);
});

test("XPOST-14: ロックは 1 つだけが取れ、中身は番号と開始時刻。外すと次が取れる", async () => {
  const dir = await tempDir();
  const table = processTable({ 111: "Tue Nov 10 09:00:00 2026", 222: "Tue Nov 10 09:01:00 2026" });
  const a = createLockFile(dir, { pid: 111, ...table });
  const b = createLockFile(dir, { pid: 222, ...table });
  assert.equal(await a.acquire(), "acquired");
  assert.equal(await b.acquire(), "busy");
  assert.equal(await readFile(join(dir, LOCK_FILE_NAME), "utf8"), "111\nTue Nov 10 09:00:00 2026");
  await b.release(); // 持っていない側が外しても消えない
  assert.ok((await readdir(dir)).includes(LOCK_FILE_NAME));
  await a.release();
  assert.equal(await b.acquire(), "acquired");
  await b.release();
  assert.deepEqual(await readdir(dir), []);
  await rm(dir, { recursive: true });
});

test("XPOST-14: 終わったプロセス・番号の使い回し（開始時刻が違う）・番号が 0 以下・中身が番号でないロックは取り直す", async () => {
  const table = processTable({ 111: "now", 999: "Mon Nov 09 08:00:00 2026" });
  for (const content of ["555\nold", "999\nSun Nov 08 08:00:00 2026", "0\nx", "-1\nx", "garbage"]) {
    const dir = await tempDir();
    await writeFile(join(dir, LOCK_FILE_NAME), content);
    const lock = createLockFile(dir, { pid: 111, ...table });
    assert.equal(await lock.acquire(), "acquired", content);
    await lock.release();
    assert.deepEqual(await readdir(dir), [], content);
    await rm(dir, { recursive: true });
  }
});

test("XPOST-14: EPERM でも開始時刻が一致すれば生きているとして扱う。開始時刻を得られなければ奪わない", async () => {
  const dir = await tempDir();
  await writeFile(join(dir, LOCK_FILE_NAME), "999\nMon Nov 09 08:00:00 2026");
  const eperm = {
    kill: () => {
      throw errno("EPERM");
    },
  };
  const same = createLockFile(dir, { pid: 111, ...eperm, startTimeOf: async (p) => (p === 999 ? "Mon Nov 09 08:00:00 2026" : "me") });
  assert.equal(await same.acquire(), "busy");
  const unknown = createLockFile(dir, { pid: 111, ...eperm, startTimeOf: async () => undefined });
  assert.equal(await unknown.acquire(), "busy");
  assert.equal(await readFile(join(dir, LOCK_FILE_NAME), "utf8"), "999\nMon Nov 09 08:00:00 2026");
  await rm(dir, { recursive: true });
});

test("XPOST-14: 3 つの実行が同時に同じ古いロックを回収しても、取れるのは 1 つだけ", async () => {
  for (let round = 0; round < 30; round++) {
    const dir = await tempDir();
    await writeFile(join(dir, LOCK_FILE_NAME), "999\nold");
    const table = processTable({ 1: "s1", 2: "s2", 3: "s3" });
    const locks = [1, 2, 3].map((pid) => createLockFile(dir, { pid, ...table }));
    const results = await Promise.all(locks.map((l) => l.acquire()));
    assert.equal(results.filter((r) => r === "acquired").length, 1, `round ${round}: ${results.join(",")}`);
    const holder = results.indexOf("acquired") + 1;
    assert.equal(await readFile(join(dir, LOCK_FILE_NAME), "utf8"), `${holder}\ns${holder}`);
    // 回収の印も一時ファイルも残らない
    assert.deepEqual(await readdir(dir), [LOCK_FILE_NAME]);
    await rm(dir, { recursive: true });
  }
});

test("XPOST-14: 回収の途中で止まった実行が残した印は、その持ち主が古ければ回収して進む", async () => {
  const dir = await tempDir();
  const stale = "999\nold";
  await writeFile(join(dir, LOCK_FILE_NAME), stale);
  const digest = createHash("sha256").update(stale).digest("hex").slice(0, 16);
  await writeFile(join(dir, `${LOCK_FILE_NAME}.reclaim.${digest}`), "888\nold");
  const lock = createLockFile(dir, { pid: 1, ...processTable({ 1: "s1" }) });
  assert.equal(await lock.acquire(), "acquired");
  await lock.release();
  assert.deepEqual(await readdir(dir), []);
  // 印の持ち主が生きていれば、奪わずに終わる
  await writeFile(join(dir, LOCK_FILE_NAME), stale);
  await writeFile(join(dir, `${LOCK_FILE_NAME}.reclaim.${digest}`), "2\ns2");
  const other = createLockFile(dir, { pid: 1, ...processTable({ 1: "s1", 2: "s2" }) });
  assert.equal(await other.acquire(), "busy");
  await rm(dir, { recursive: true });
});
