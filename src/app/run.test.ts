// 実行の流れの試験。取得・投稿・記録・ロック・待ち・時刻は偽物に差し替える（本物の X と Slack へは要求しない）。
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { run } from "./run.ts";
import { inspect } from "./inspect.ts";
import { containsSecret, fakePost, fetched, harness, FAKE_SECRETS, TARGET_USER_ID } from "./fakes.ts";
import type { Harness } from "./fakes.ts";
import type { FetchResult } from "./ports.ts";
import { RETRY_DELAYS_MS } from "./retry.ts";
import { TRANSLATE_RETRY_DELAY_MS } from "./translate.ts";
import { createRecordFile, RECORD_FILE_NAME } from "../adapters/record-file.ts";
import { createLockFile } from "../adapters/lock-file.ts";

const fail = (kind: "temporary" | "login-rejected" | "target-unavailable" | "abnormal", retryable = kind === "temporary"): FetchResult => ({
  ok: false,
  kind,
  retryable,
  requests: 1,
});

/** 投稿の口が受け取った通のうち、ポストの通（URL の行で終わるもの）の URL の ID。 */
function postedIds(h: Harness): string[] {
  return h.poster.received.flatMap((t) => {
    const m = /\/status\/(\d+)$/.exec(t);
    return m ? [m[1] as string] : [];
  });
}

function assertNoSecrets(h: Harness): void {
  for (const text of [...h.lines, ...h.poster.attempts]) assert.ok(!containsSecret(text), text);
}

test("XPOST-1 / XPOST-11: 記録に無い 2 件を古い順に 1 通ずつ投稿し、記録して件数 2 で終わる", async () => {
  const h = harness({
    record: { AnthropicAI: ["10", "20"] },
    fetch: { AnthropicAI: fetched([fakePost(40, { postedAt: new Date("2026-11-09T01:30:00Z") }), fakePost(30), fakePost(20), fakePost(10)]) },
  });
  assert.equal(await run(h.deps), 0);
  assert.deepEqual(postedIds(h), ["30", "40"]);
  assert.equal(h.poster.received.length, 2);
  assert.ok(h.poster.received[1]?.startsWith("@AnthropicAI\n2026-11-09 10:30（日本時間）\n本文 40\n"));
  assert.deepEqual(h.record.ids("AnthropicAI"), ["10", "20", "30", "40"]);
  assert.deepEqual(h.lines, ["通知した件数: 2"]);
  assert.deepEqual(h.fetcher.calls, ["AnthropicAI"]);
  assert.equal(h.lock.released, 1);
  assertNoSecrets(h);
});

test("XPOST-2 / XPOST-3: 2 回目は再び投稿せず、新しいポストが無い旨の 1 通だけ", async () => {
  const h = harness({ record: { AnthropicAI: ["10"] }, fetch: { AnthropicAI: fetched([fakePost(20), fakePost(10)]) } });
  assert.equal(await run(h.deps), 0);
  h.poster.received = [];
  h.lines.length = 0;
  assert.equal(await run(h.deps), 0);
  assert.deepEqual(h.poster.received, ["新しいポストはありません（確かめたアカウント: @AnthropicAI）"]);
  assert.deepEqual(h.lines, ["通知した件数: 0"]);
});

test("XPOST-4 / XPOST-12: 記録が無いときは最も新しい 1 件だけを投稿し、残りを記録する", async () => {
  const posts = Array.from({ length: 20 }, (_, i) => fakePost(100 + i));
  const h = harness({ fetch: { AnthropicAI: fetched([fakePost(150, { isRetweet: true }), ...posts]) } });
  assert.equal(await run(h.deps), 0);
  assert.deepEqual(postedIds(h), ["119"]);
  assert.equal(h.record.ids("AnthropicAI")?.length, 21);
  // 先に 20 件（投稿しないもの）を記録し、投稿の後で 1 件を足す
  assert.equal(h.record.writes[0]?.ids.length, 20);
  assert.deepEqual(h.record.writes[1]?.ids, ["119"]);
  h.poster.received = [];
  assert.equal(await run(h.deps), 0);
  assert.deepEqual(postedIds(h), []);
});

test("XPOST-4: 最も新しい 1 件の投稿に失敗したら、それを記録せず、次の実行で投稿する", async () => {
  const h = harness({ fetch: { AnthropicAI: fetched([fakePost(2), fakePost(1)]) } });
  h.poster.fail = () => ({ ok: false, retryable: false });
  assert.equal(await run(h.deps), 1);
  assert.deepEqual(h.record.ids("AnthropicAI"), ["1"]);
  h.poster.fail = () => undefined;
  assert.equal(await run(h.deps), 0);
  assert.deepEqual(postedIds(h), ["2"]);
});

test("XPOST-12: 記録のファイルやディレクトリが消えたら、初めての実行と同じ扱い", async () => {
  const base = await mkdtemp(join(tmpdir(), "x-dev-rss-test-"));
  const dir = join(base, "state");
  const posts = [fakePost(3), fakePost(2), fakePost(1)];
  for (const removal of ["file", "dir"] as const) {
    const first = harness({ fetch: { AnthropicAI: fetched(posts) } });
    first.deps.record = createRecordFile(dir);
    await run(first.deps);
    if (removal === "file") await rm(join(dir, RECORD_FILE_NAME));
    else await rm(dir, { recursive: true });
    const h = harness({ fetch: { AnthropicAI: fetched(posts) } });
    h.deps.record = createRecordFile(dir);
    assert.equal(await run(h.deps), 0);
    assert.deepEqual(postedIds(h), ["3"], removal);
  }
  await rm(base, { recursive: true });
});

test("XPOST-5: 候補は数える対象の新しいほうから 20 件で、それより古いものは記録に無くても投稿しない", async () => {
  const list = [];
  for (let i = 1; i <= 25; i++) {
    list.push(fakePost(1000 + i * 10));
    if (i % 4 === 0) list.push(fakePost(1000 + i * 10 + 1, { isRetweet: true }), fakePost(1000 + i * 10 + 2, { isReply: true }));
  }
  const h = harness({ record: { AnthropicAI: ["1250"] }, fetch: { AnthropicAI: fetched(list.reverse(), "enough") } });
  assert.equal(await run(h.deps), 0);
  assert.equal(postedIds(h).length, 19);
  assert.equal(postedIds(h)[0], "1060");
});

test("XPOST-6（利用者の判断で改めた規則）: 通常のポストだけを投稿し、引用・返信・リポストの 5 件とも記録する。2 回目は何も投稿しない", async () => {
  const posts = [
    fakePost(1),
    fakePost(2, { isRetweet: true }),
    fakePost(3, { isQuote: true }),
    fakePost(4, { isReply: true }), // ほかのアカウントへの返信
    fakePost(5, { isReply: true }), // 自分のポストへの返信
    fakePost(6, { authorId: "999" }), // 会話のまとまりに入る他人のポスト（記録しない）
  ];
  const h = harness({ record: { AnthropicAI: ["0"] }, fetch: { AnthropicAI: fetched(posts) } });
  assert.equal(await run(h.deps), 0);
  assert.deepEqual(postedIds(h), ["1"]);
  assert.deepEqual(h.record.ids("AnthropicAI"), ["0", "1", "2", "3", "4", "5"]);
  h.poster.received = [];
  await run(h.deps);
  assert.deepEqual(postedIds(h), []);
});

for (const kind of ["temporary", "login-rejected", "target-unavailable", "abnormal"] as const) {
  test(`XPOST-7: 取得の失敗（${kind}）では記録が変わらず、失敗の 1 通と 1 行で、終了コード 1`, async () => {
    const h = harness({ record: { AnthropicAI: ["1"] }, fetch: { AnthropicAI: fail(kind) } });
    assert.equal(await run(h.deps), 1);
    assert.equal(h.poster.received.length, 1);
    assert.ok(h.poster.received[0]?.startsWith("X からの取得に失敗しました\n@AnthropicAI: "));
    assert.ok(!h.poster.received.some((t) => t.includes("新しいポストはありません")));
    assert.deepEqual(h.record.writes, []);
    assert.ok(h.lines[0]?.includes("@AnthropicAI"));
    assert.equal(h.lines.length, 2); // 失敗の 1 行と件数の 1 行
    assert.deepEqual(h.fetcher.calls.length, kind === "temporary" ? 3 : 1);
    assertNoSecrets(h);
  });
}

test("XPOST-8: D の投稿で止まり、E を試さず、記録は C だけ。失敗の知らせは投稿しない。2 回目で D、E の順", async () => {
  const posts = [fakePost(5), fakePost(4), fakePost(3)]; // C=3, D=4, E=5
  const h = harness({ record: { AnthropicAI: ["1"] }, fetch: { AnthropicAI: fetched(posts) } });
  h.poster.fail = (text) => (text.endsWith("/status/4") ? { ok: false, retryable: true } : undefined);
  assert.equal(await run(h.deps), 1);
  assert.deepEqual(postedIds(h), ["3"]);
  assert.equal(h.poster.attempts.filter((t) => t.endsWith("/status/4")).length, 3);
  assert.ok(!h.poster.attempts.some((t) => t.endsWith("/status/5")));
  assert.equal(h.poster.attempts.length, 4);
  assert.deepEqual(h.record.ids("AnthropicAI"), ["1", "3"]);
  assert.deepEqual(h.lines, ["Slack への投稿に失敗したため止めました（通知した件数: 1）"]);
  assert.equal(h.lock.released, 1);
  h.poster.fail = () => undefined;
  h.poster.received = [];
  assert.equal(await run(h.deps), 0);
  assert.deepEqual(postedIds(h), ["4", "5"]);
});

test("XPOST-8 / D8: 上限より長い Retry-After の 429 は待たずに投稿の失敗にする", async () => {
  const h = harness({ record: { AnthropicAI: ["1"] }, fetch: { AnthropicAI: fetched([fakePost(2)]) } });
  h.poster.fail = () => ({ ok: false, retryable: true, retryAfterSeconds: 61 });
  assert.equal(await run(h.deps), 1);
  assert.equal(h.poster.attempts.length, 1);
  assert.ok(!h.time.sleeps.includes(61000));
});

test("XPOST-9: 秘匿値が足りなければ、取得と投稿の口を作らず、足りない名前の 1 行で終了コード 1", async () => {
  const h = harness({ secrets: { load: async () => ({ ok: false, reason: "missing", missing: ["X_CT0"], malformed: [] }) } });
  assert.equal(await run(h.deps), 1);
  assert.deepEqual(h.lines, ["秘匿値が足りません: X_CT0"]);
  assert.deepEqual([h.fetcherMade, h.posterMade, h.fetcher.calls.length, h.poster.attempts.length], [0, 0, 0, 0]);
  assert.equal(h.lock.held, false);
});

test("XPOST-13: 記録が読めなければポストを投稿せず、記録のファイルのバイト列は変わらない", async () => {
  const dir = await mkdtemp(join(tmpdir(), "x-dev-rss-test-"));
  const path = join(dir, RECORD_FILE_NAME);
  await writeFile(path, '{"version": 9}');
  const before = await readFile(path);
  const h = harness({ fetch: { AnthropicAI: fetched([fakePost(1)]) } });
  h.deps.record = createRecordFile(dir);
  assert.equal(await run(h.deps), 1);
  assert.deepEqual(await readFile(path), before);
  assert.deepEqual(h.fetcher.calls, []);
  assert.deepEqual(h.poster.received, ["通知済みの記録が読めないため、ポストを投稿しませんでした（記録はそのまま残しています）"]);
  assert.deepEqual(h.lines, ["通知済みの記録が読めないため、ポストを投稿しませんでした（記録はそのまま残しています）"]);
  assertNoSecrets(h);
  await rm(dir, { recursive: true });
});

test("XPOST-14: ほかの実行がロックを持っていれば、何も呼ばず、記録も変えずに終了コード 0", async () => {
  const dir = await mkdtemp(join(tmpdir(), "x-dev-rss-test-"));
  const other = createLockFile(dir, { pid: 4242, kill: () => undefined });
  assert.equal(await other.acquire(), "acquired");
  const h = harness({ fetch: { AnthropicAI: fetched([fakePost(1)]) } });
  h.deps.lock = createLockFile(dir, { pid: 4343, kill: () => undefined });
  h.deps.record = createRecordFile(dir);
  assert.equal(await run(h.deps), 0);
  assert.deepEqual(h.lines, ["ほかの実行が動いているため、何もせずに終わります"]);
  assert.deepEqual([h.fetcher.calls.length, h.poster.attempts.length], [0, 0]);
  assert.deepEqual(await readdir(dir), ["run.lock"]);
  await other.release();
  await rm(dir, { recursive: true });
});

test("XPOST-15: 設定が読めなければ取得せず、記録も変えず、1 通と 1 行で終了コード 1", async () => {
  const h = harness({ accounts: null });
  assert.equal(await run(h.deps), 1);
  assert.deepEqual(h.fetcher.calls, []);
  assert.deepEqual(h.record.writes, []);
  assert.deepEqual(h.poster.received, ["対象のアカウントの設定が無いか読めないため、取得しませんでした"]);
  assert.deepEqual(h.lines, ["対象のアカウントの設定が無いか読めないため、取得しませんでした"]);
});

test("XPOST-16: 20 位以内の固定表示のポストは 1 回だけ投稿され、21 位より古いときは投稿されない", async () => {
  const base = Array.from({ length: 25 }, (_, i) => fakePost(10000 + (i + 1) * 10)).reverse();
  for (const [pid, expected] of [
    ["20000", true],
    ["10065", true],
    ["10055", false],
    ["10", false],
  ] as const) {
    const pinned = fakePost(pid, { isPinned: true });
    const h = harness({ record: { AnthropicAI: ["10010"] }, fetch: { AnthropicAI: fetched([pinned, ...base], "enough") } });
    await run(h.deps);
    assert.equal(postedIds(h).includes(pid), expected, pid);
    if (pid === "10065") assert.ok(!postedIds(h).includes("10060"));
    h.poster.received = [];
    await run(h.deps);
    assert.ok(!postedIds(h).includes(pid), pid);
  }
});

test("XPOST-17: 2 つのアカウントの記録に無いポストを 1 通ずつ投稿し、2 回目は名前を並べた 1 通だけ", async () => {
  const h = harness({
    accounts: ["AnthropicAI", "Q"],
    record: { AnthropicAI: ["1"], q: ["1"] },
    fetch: {
      AnthropicAI: fetched([fakePost(2), fakePost(1)]),
      Q: { ok: true, targetUserId: TARGET_USER_ID, posts: [fakePost(3, { url: "https://x.com/Q/status/3" }), fakePost(1)], stop: "exhausted", requests: 2 },
    },
  });
  assert.equal(await run(h.deps), 0);
  assert.equal(h.poster.received.length, 2);
  assert.ok(h.poster.received[0]?.startsWith("@AnthropicAI\n"));
  assert.ok(h.poster.received[1]?.startsWith("@Q\n"));
  assert.deepEqual(h.lines, ["通知した件数: 2"]);
  h.poster.received = [];
  assert.equal(await run(h.deps), 0);
  assert.deepEqual(h.poster.received, ["新しいポストはありません（確かめたアカウント: @AnthropicAI、@Q）"]);
});

test("XPOST-17: 一方の記録が無くても、他方の投稿に影響しない", async () => {
  const h = harness({
    accounts: ["AnthropicAI", "Q"],
    record: { AnthropicAI: ["1"] },
    fetch: { AnthropicAI: fetched([fakePost(3), fakePost(2), fakePost(1)]), Q: fetched([fakePost(30), fakePost(20)]) },
  });
  assert.equal(await run(h.deps), 0);
  assert.deepEqual(postedIds(h), ["2", "3", "30"]);
  assert.deepEqual(h.record.ids("Q"), ["20", "30"]);
});

test("XPOST-18: Q の取得だけ失敗すれば、@AnthropicAI は投稿・記録し、Q の記録は変わらず、失敗の 1 通", async () => {
  const h = harness({
    accounts: ["AnthropicAI", "Q"],
    record: { AnthropicAI: ["1"], q: ["5"] },
    fetch: { AnthropicAI: fetched([fakePost(2), fakePost(1)]), Q: fail("temporary") },
  });
  assert.equal(await run(h.deps), 1);
  assert.deepEqual(postedIds(h), ["2"]);
  assert.deepEqual(h.record.ids("Q"), ["5"]);
  assert.equal(h.poster.received[1], "X からの取得に失敗しました\n@Q: 通信に失敗しました");
  assert.ok(h.lines.some((l) => l.includes("@Q")));
  assertNoSecrets(h);
});

test("XPOST-19: 上限を超えるポストは切り詰めた 1 通で投稿し、記録する", async () => {
  const h = harness({ record: { AnthropicAI: ["1"] }, fetch: { AnthropicAI: fetched([fakePost(2, { text: "<&>".repeat(500) })]) }, textLimit: 300 });
  assert.equal(await run(h.deps), 0);
  const text = h.poster.received[0] ?? "";
  assert.ok(h.poster.measure(text) <= 300);
  assert.ok(text.includes("…（長いため途中まで）"));
  assert.ok(text.endsWith("/status/2"));
  assert.deepEqual(h.record.ids("AnthropicAI"), ["1", "2"]);
});

test("XPOST-20: 途中でやめて記録と重ならなければ、投稿に加えて漏れのおそれの 1 通と 1 行。終了コード 0", async () => {
  const posts = Array.from({ length: 20 }, (_, i) => fakePost(100 + i));
  const h = harness({ record: { AnthropicAI: ["1"] }, fetch: { AnthropicAI: fetched(posts, "enough") } });
  assert.equal(await run(h.deps), 0);
  assert.equal(postedIds(h).length, 20);
  const notice = "取得した件数より古いポストが通知されずに漏れたおそれがあります: @AnthropicAI";
  assert.equal(h.poster.received[20], notice);
  assert.deepEqual(h.lines, [notice, "通知した件数: 20"]);
  assertNoSecrets(h);
});

test("XPOST-21: 一時的な失敗は 5 秒・15 秒を空けてやり直し、失敗が無いときと同じ結果", async () => {
  const h = harness({
    record: { AnthropicAI: ["1"] },
    fetch: { AnthropicAI: [fail("temporary"), fail("temporary"), fetched([fakePost(2), fakePost(1)])] },
  });
  h.poster.fail = (_t, attempt) => (attempt === 1 ? { ok: false, retryable: true } : undefined);
  assert.equal(await run(h.deps), 0);
  assert.deepEqual(postedIds(h), ["2"]);
  assert.equal(h.poster.received.length, 1);
  assert.deepEqual(h.time.sleeps.slice(0, 2), [...RETRY_DELAYS_MS]);
  assert.equal(h.time.sleeps[2], 5000);
});

test("XPOST-21 / D8: Slack の 429 のあとは Retry-After の秒数を待つ", async () => {
  const h = harness({ record: { AnthropicAI: ["1"] }, fetch: { AnthropicAI: fetched([fakePost(2)]) } });
  h.poster.fail = (_t, attempt) => (attempt <= 2 ? { ok: false, retryable: true, retryAfterSeconds: 7 } : undefined);
  assert.equal(await run(h.deps), 0);
  assert.deepEqual(h.time.sleeps, [7000, 7000]);
  assert.equal(postedIds(h).length, 1);
});

test("XPOST-22: ログインの拒否はやり直さず、待ちも呼ばない", async () => {
  const h = harness({ record: { AnthropicAI: ["1"] }, fetch: { AnthropicAI: fail("login-rejected") } });
  assert.equal(await run(h.deps), 1);
  assert.equal(h.fetcher.calls.length, 1);
  assert.deepEqual(h.time.sleeps, []);
  assert.equal(h.poster.received[0], "X からの取得に失敗しました\n@AnthropicAI: 取得用のアカウントのログインが拒まれました");
});

test("XPOST-23: 両方の取得に失敗したら、失敗の知らせは名前を並べた 1 通だけ", async () => {
  const h = harness({
    accounts: ["AnthropicAI", "Q"],
    record: { AnthropicAI: ["1"], q: ["2"] },
    fetch: { AnthropicAI: fail("login-rejected"), Q: fail("target-unavailable") },
  });
  assert.equal(await run(h.deps), 1);
  assert.equal(h.poster.received.length, 1);
  assert.ok(h.poster.received[0]?.includes("@AnthropicAI: ") && h.poster.received[0]?.includes("@Q: "));
  assert.deepEqual(h.record.writes, []);
});

test("V6: 投稿の口の 2 回目以降の呼び出しの前に 1.1 秒以上を空ける（まとめの通も同じ）", async () => {
  const h = harness({
    accounts: ["AnthropicAI", "Q"],
    record: { AnthropicAI: ["1"], q: ["9"] },
    fetch: { AnthropicAI: fetched([fakePost(5), fakePost(4), fakePost(3)], "limit"), Q: fail("login-rejected") },
  });
  const callTimes: number[] = [];
  h.poster.fail = () => {
    callTimes.push(h.time.now());
    return undefined;
  };
  assert.equal(await run(h.deps), 1);
  assert.equal(callTimes.length, 5); // ポスト 3 通、漏れのおそれ、取得の失敗
  for (let i = 1; i < callTimes.length; i++) assert.ok((callTimes[i] ?? 0) - (callTimes[i - 1] ?? 0) >= 1100);
  assert.ok(h.time.sleeps.every((ms) => ms >= 1100));
});

test("XPOST-10: 各場面で、出力と投稿に架空の秘匿値が含まれない（記録のファイルにも）", async () => {
  const dir = await mkdtemp(join(tmpdir(), "x-dev-rss-test-"));
  const h = harness({
    accounts: ["AnthropicAI", "Q"],
    fetch: { AnthropicAI: fetched([fakePost(2, { text: "本文" }), fakePost(1)], "limit"), Q: fail("login-rejected") },
  });
  h.deps.record = createRecordFile(dir);
  await run(h.deps);
  assertNoSecrets(h);
  for (const name of await readdir(dir)) assert.ok(!containsSecret(await readFile(join(dir, name), "utf8")));
  assert.ok(!JSON.stringify(FAKE_SECRETS).includes("本文"));
  await rm(dir, { recursive: true });
});

test("V1（試し取得）: 投稿も記録もせず、各ポストの行と、取得の止まり方と要求の回数を出す", async () => {
  const h = harness({ fetch: { AnthropicAI: fetched([fakePost(3, { isPinned: true }), fakePost(2, { isReply: true }), fakePost(1, { isRetweet: true })], "enough") } });
  const code = await inspect({ ...h.deps });
  assert.equal(code, 0);
  assert.deepEqual(h.poster.attempts, []);
  assert.equal(h.posterMade, 0);
  assert.deepEqual(h.record.writes, []);
  assert.equal(h.lines[0], "@AnthropicAI");
  assert.match(h.lines[1] ?? "", /^3 \d{4}-\d{2}-\d{2} \d{2}:\d{2}（日本時間） 種類=通常 固定表示=はい 順位=1$/);
  assert.match(h.lines[2] ?? "", /種類=返信 固定表示=いいえ 順位=-$/);
  assert.match(h.lines[3] ?? "", /種類=リポスト/);
  assert.deepEqual(h.lines.slice(4), ["取得: 通常のポストが 20 件そろったので途中でやめた", "X への要求の回数: 2"]);
  assert.equal(h.lock.released, 1);
});

test("XPOST-20 (6): 上限で止まり、見つかった通常のポストが記録に 1 件も無ければ、候補を投稿し、漏れのおそれを知らせ、「新しいポストはありません」は送らない", async () => {
  const h = harness({ record: { AnthropicAI: ["1"] }, fetch: { AnthropicAI: fetched([fakePost(3, { isRetweet: true }), fakePost(2)], "limit") } });
  assert.equal(await run(h.deps), 0);
  assert.deepEqual(postedIds(h), ["2"]);
  assert.ok(h.poster.received.includes("取得した件数より古いポストが通知されずに漏れたおそれがあります: @AnthropicAI"));
  assert.ok(!h.poster.received.some((t) => t.startsWith("新しいポストはありません")));
  // 見つかった通常のポストに記録済みのものがあれば知らせず、新しいポストが無ければその旨を送る
  const seen = harness({ record: { AnthropicAI: ["2"] }, fetch: { AnthropicAI: fetched([fakePost(2)], "limit") } });
  assert.equal(await run(seen.deps), 0);
  assert.deepEqual(seen.poster.received, ["新しいポストはありません（確かめたアカウント: @AnthropicAI）"]);
  // 通常のポストが 1 件も見つからず記録とも重ならなければ、知らせるだけで「新しいポストはありません」は送らない
  const none = harness({ record: { AnthropicAI: ["2"] }, fetch: { AnthropicAI: fetched([fakePost(9, { isRetweet: true })], "limit") } });
  assert.equal(await run(none.deps), 0);
  assert.deepEqual(none.poster.received, ["取得した件数より古いポストが通知されずに漏れたおそれがあります: @AnthropicAI"]);
  // 並びの終わりまで取得したときは知らせない
  const done = harness({ record: { AnthropicAI: ["2"] }, fetch: { AnthropicAI: fetched([fakePost(2)], "exhausted") } });
  await run(done.deps);
  assert.deepEqual(done.poster.received, ["新しいポストはありません（確かめたアカウント: @AnthropicAI）"]);
});

test("XPOST-21: Slack が受け取った後に応答だけが失われたら、やり直して同じポストが 2 通届く（許容）。記録は 1 件で終了コード 0", async () => {
  const h = harness({ record: { AnthropicAI: ["1"] }, fetch: { AnthropicAI: fetched([fakePost(2)]) } });
  h.poster.fail = (text, attempt) => {
    if (attempt === 1) {
      h.poster.received.push(text); // Slack には届いた
      return { ok: false, retryable: true }; // 応答だけが失われた
    }
    return undefined;
  };
  assert.equal(await run(h.deps), 0);
  assert.deepEqual(postedIds(h), ["2", "2"]);
  assert.deepEqual(h.record.ids("AnthropicAI"), ["1", "2"]);
});

test("XPOST-21: Slack が受け取ったと応答した投稿はやり直さない", async () => {
  const h = harness({ record: { AnthropicAI: ["1"] }, fetch: { AnthropicAI: fetched([fakePost(3), fakePost(2)]) } });
  assert.equal(await run(h.deps), 0);
  assert.equal(h.poster.attempts.filter((t) => t.endsWith("/status/2")).length, 1);
});

test("XPOST-24: 投稿した後に記録の書き込みに失敗したら止め、1 行と 1 通で知らせて終了コード 1。直した次の実行で同じポストが再び投稿される", async () => {
  const h = harness({ record: { AnthropicAI: ["1"] }, fetch: { AnthropicAI: fetched([fakePost(3), fakePost(2)]) } });
  h.record.failAdd = (_a, ids) => ids.includes("2");
  assert.equal(await run(h.deps), 1);
  assert.deepEqual(postedIds(h), ["2"]);
  assert.ok(!h.poster.attempts.some((t) => t.endsWith("/status/3")));
  const notice = "通知済みの記録に書き込めなかったため止めました（記録を直してから実行すると、同じポストが再び投稿されることがあります）";
  assert.deepEqual(h.lines, [notice]);
  assert.equal(h.poster.received[1], notice);
  assert.equal(h.lock.released, 1);
  h.record.failAdd = () => false;
  h.poster.received = [];
  assert.equal(await run(h.deps), 0);
  assert.deepEqual(postedIds(h), ["2", "3"]);
});

test("XPOST-24: 記録の書き込みで止めるときは、それまでに集めた取得の失敗と漏れのおそれも同じ 1 通に入れる", async () => {
  const h = harness({
    accounts: ["Q", "M", "AnthropicAI"],
    record: { q: ["2"], m: ["1"], AnthropicAI: ["1"] },
    fetch: { Q: fail("login-rejected"), M: fetched([fakePost(5), fakePost(4)], "limit"), AnthropicAI: fetched([fakePost(9)]) },
  });
  h.record.failAdd = (account) => account === "AnthropicAI";
  assert.equal(await run(h.deps), 1);
  const notice = h.poster.received.at(-1) ?? "";
  assert.ok(notice.startsWith("通知済みの記録に書き込めなかったため止めました"));
  assert.ok(notice.includes("漏れたおそれがあります: @M"));
  assert.ok(notice.includes("@Q: "));
  assert.equal(h.poster.received.filter((t) => t.includes("@Q: ")).length, 1);
  assert.equal(h.lines.length, 3);
});

test("XPOST-24: 失敗の知らせの投稿にも失敗したら、出力の 1 行だけ", async () => {
  const h = harness({ record: { AnthropicAI: ["1"] }, fetch: { AnthropicAI: fetched([fakePost(2)]) } });
  h.record.failAdd = () => true;
  h.poster.fail = (text) => (text.startsWith("通知済みの記録に書き込めなかった") ? { ok: false, retryable: false } : undefined);
  assert.equal(await run(h.deps), 1);
  assert.deepEqual(postedIds(h), ["2"]);
  assert.equal(h.lines.length, 1);
  assert.ok(h.lines[0]?.startsWith("通知済みの記録に書き込めなかった"));
});

test("秘匿値のファイルの権限の問題は、それぞれの決まった 1 行で終了コード 1", async () => {
  for (const reason of ["insecure", "foreign-owner", "unreadable"] as const) {
    const h = harness({ secrets: { load: async () => ({ ok: false, reason }) } });
    assert.equal(await run(h.deps), 1);
    assert.equal(h.lines.length, 1);
    assert.equal(h.fetcherMade + h.posterMade, 0);
  }
});

// ---- 翻訳（計画の手順 6。仕様 XPJA） ----

const EN = "We're releasing a new model today.";
const JA = "本日、新しいモデルを公開します。";
const XPJA2 = "Run `claude --help` with @claudeai and read https://www.anthropic.com/news #AI";
const FAKE_TOKEN = "sk-ant-oat01-FAKE.not.a.real.token";
const TRANSLATED = "（機械翻訳）";
const FAILED = "（翻訳に失敗したため原文のまま）";

function enPost(id: number, text: string) {
  return fakePost(id, { text, postedAt: new Date("2026-11-09T01:30:00Z") });
}

function message(id: number, body: string, mark?: string): string {
  return ["@AnthropicAI", "2026-11-09 10:30（日本時間）", body, ...(mark === undefined ? [] : [mark]), `https://x.com/AnthropicAI/status/${id}`].join("\n");
}

function assertNoLeaks(h: Harness): void {
  assertNoSecrets(h);
  for (const text of [...h.lines, ...h.poster.attempts]) assert.ok(!text.includes(FAKE_TOKEN), text);
  for (const call of h.translator.calls) assert.ok(!containsSecret(call.text), call.text);
}

test("XPJA-1: 英語のポストは、訳した本文と機械翻訳の印を、見出し → 本文 → 印 → URL の順の 1 通で投稿し、原文を含めない", async () => {
  const h = harness({ record: { AnthropicAI: ["0"] }, fetch: { AnthropicAI: fetched([enPost(1, EN), fakePost(0)]) } });
  h.translator.set(EN, { ok: true, text: JA });
  assert.equal(await run(h.deps), 0);
  assert.deepEqual(h.poster.received, [message(1, JA, TRANSLATED)]);
  assert.ok(!h.poster.received[0]?.includes(EN));
  assert.ok(!h.poster.received[0]?.includes(FAILED));
  assert.deepEqual(h.lines, ["通知した件数: 1"]);
  assert.deepEqual(h.record.ids("AnthropicAI"), ["0", "1"]);
  assert.deepEqual(h.translator.calls, [{ text: EN, attempt: 1 }]);
  assertNoLeaks(h);
});

test("XPJA-2: 守る部分を残し、日本語の文字に隣り合う訳文は通り、機械翻訳の印が付く", async () => {
  const good = "`claude --help`を@claudeaiと一緒に実行し、https://www.anthropic.com/newsをご覧ください #AI";
  const h = harness({ record: { AnthropicAI: ["0"] }, fetch: { AnthropicAI: fetched([enPost(1, XPJA2)]) } });
  h.translator.set(XPJA2, { ok: true, text: good });
  assert.equal(await run(h.deps), 0);
  assert.deepEqual(h.poster.received, [message(1, good, TRANSLATED)]);
});

test("XPJA-2: 通らないべき訳文は、2 回試しても翻訳の失敗として原文に失敗の印を付ける", async () => {
  const good = "`claude --help`を@claudeai と一緒に実行し、https://www.anthropic.com/news をご覧ください #AI";
  const bad = [
    good.replace(" #AI", ""),
    good.replace("@claudeai", "@Claudeai"),
    good.replace("@claudeai", "@claudeai2"),
    `${good} https://www.anthropic.com/news`,
    `${good} https://example.com/x`,
    `${good} @someone`,
    `${good} ${XPJA2}`,
    "了解しました",
  ];
  for (const translated of bad) {
    const h = harness({ record: { AnthropicAI: ["0"] }, fetch: { AnthropicAI: fetched([enPost(1, XPJA2)]) } });
    h.translator.set(XPJA2, { ok: true, text: translated });
    assert.equal(await run(h.deps), 0, translated);
    assert.deepEqual(h.poster.received, [message(1, XPJA2, FAILED)], translated);
    assert.deepEqual(h.translator.calls.map((c) => c.attempt), [1, 2], translated);
    assert.deepEqual(h.lines, ["翻訳に失敗したため原文のまま投稿したポストの件数: 1", "通知した件数: 1"], translated);
    assert.deepEqual(h.record.ids("AnthropicAI"), ["0", "1"], translated);
  }
});

test("XPJA-3: 2 回とも失敗したら、原文の全文に失敗の印を付けて投稿・記録し、件数の行の前に失敗の 1 行。終了コード 0", async () => {
  for (const reason of ["unavailable", "failed", "timeout"] as const) {
    const h = harness({ record: { AnthropicAI: ["0"] }, fetch: { AnthropicAI: fetched([enPost(1, EN)]) } });
    h.translator.set(EN, { ok: false, reason });
    assert.equal(await run(h.deps), 0, reason);
    assert.deepEqual(h.poster.received, [message(1, EN, FAILED)], reason);
    assert.ok(!h.poster.received[0]?.includes(TRANSLATED));
    assert.deepEqual(h.lines, ["翻訳に失敗したため原文のまま投稿したポストの件数: 1", "通知した件数: 1"], reason);
    assert.deepEqual(h.record.ids("AnthropicAI"), ["0", "1"], reason);
    // 失敗を知らせる別の通は無い
    assert.equal(h.poster.attempts.length, 1, reason);
    assertNoLeaks(h);
  }
});

test("XPJA-3: 翻訳に失敗したポストが 2 件以上でも、失敗の行は件数を含む 1 行", async () => {
  const other = "Another update from our team today.";
  const h = harness({ record: { AnthropicAI: ["0"] }, fetch: { AnthropicAI: fetched([enPost(2, other), enPost(1, EN)]) } });
  // 原文の丸写し（5 語以上）は検証を通らない
  h.translator.fallback = (text) => ({ ok: true, text });
  assert.equal(await run(h.deps), 0);
  assert.deepEqual(h.poster.received, [message(1, EN, FAILED), message(2, other, FAILED)]);
  assert.deepEqual(h.lines, ["翻訳に失敗したため原文のまま投稿したポストの件数: 2", "通知した件数: 2"]);
});

test("XPJA-3 / D14: 翻訳の口が例外を投げても、失敗の扱いで終了コード 0。例外の文面は出ない", async () => {
  const h = harness({ record: { AnthropicAI: ["0"] }, fetch: { AnthropicAI: fetched([enPost(1, EN)]) } });
  h.translator.set(EN, "throw");
  assert.equal(await run(h.deps), 0);
  assert.deepEqual(h.poster.received, [message(1, EN, FAILED)]);
  assert.deepEqual(h.lines, ["翻訳に失敗したため原文のまま投稿したポストの件数: 1", "通知した件数: 1"]);
  assertNoLeaks(h);
});

test("XPJA-3: 2 回目の試みは attempt 2 で、1 回目との間に 5 秒待つ", async () => {
  const h = harness({ record: { AnthropicAI: ["0"] }, fetch: { AnthropicAI: fetched([enPost(1, EN)]) } });
  h.translator.set(EN, { ok: false, reason: "timeout" }, { ok: true, text: JA });
  assert.equal(await run(h.deps), 0);
  assert.deepEqual(h.translator.calls, [
    { text: EN, attempt: 1 },
    { text: EN, attempt: 2 },
  ]);
  assert.deepEqual(h.time.sleeps, [5000]);
  assert.deepEqual(h.poster.received, [message(1, JA, TRANSLATED)]);
  assert.deepEqual(h.lines, ["通知した件数: 1"]);
});

test("XPJA-3 / D5: 2 回とも接続の失敗だったら、同じ実行の後のポストは訳さずに失敗の印を付ける", async () => {
  const other = "Another update from our team today.";
  const h = harness({ record: { AnthropicAI: ["0"] }, fetch: { AnthropicAI: fetched([enPost(3, JA), enPost(2, other), enPost(1, EN)]) } });
  h.translator.set(EN, { ok: false, reason: "failed" });
  assert.equal(await run(h.deps), 0);
  assert.deepEqual(h.poster.received, [message(1, EN, FAILED), message(2, other, FAILED), message(3, JA)]);
  assert.deepEqual(h.translator.calls.map((c) => c.text), [EN, EN]);
  assert.deepEqual(h.lines, ["翻訳に失敗したため原文のまま投稿したポストの件数: 2", "通知した件数: 3"]);
});

test("XPJA-3: 投稿の失敗で止まるときも、それまでの翻訳の失敗の 1 行を出す", async () => {
  const other = "Another update from our team today.";
  const h = harness({ record: { AnthropicAI: ["0"] }, fetch: { AnthropicAI: fetched([enPost(2, other), enPost(1, EN)]) } });
  h.translator.set(EN, { ok: false, reason: "failed" });
  h.poster.fail = (text) => (text.includes("/status/2") ? { ok: false, retryable: false } : undefined);
  assert.equal(await run(h.deps), 1);
  assert.deepEqual(h.lines, ["翻訳に失敗したため原文のまま投稿したポストの件数: 2", "Slack への投稿に失敗したため止めました（通知した件数: 1）"]);
});

test("XPJA-3: 記録の書き込みの失敗で止まるときも、それまでの翻訳の失敗の 1 行を出す", async () => {
  const h = harness({ record: { AnthropicAI: ["0"] }, fetch: { AnthropicAI: fetched([enPost(1, EN)]) } });
  h.translator.set(EN, { ok: false, reason: "failed" });
  h.record.failAdd = () => true;
  assert.equal(await run(h.deps), 1);
  assert.equal(h.lines[0], "翻訳に失敗したため原文のまま投稿したポストの件数: 1");
  assert.ok(h.lines.includes("通知済みの記録に書き込めなかったため止めました（記録を直してから実行すると、同じポストが再び投稿されることがあります）"));
});

test("XPJA-4: 日本語の文だけのポストと URL だけのポストは、翻訳を呼ばず、原文と 1 文字も違わない本文で印なし", async () => {
  const url = "https://www.anthropic.com/news";
  const ja = "本日、新しいモデルを公開しました。";
  for (const setup of [(h: Harness) => h.translator.set(ja, { ok: true, text: "x" }), (h: Harness) => (h.translator.fallback = () => ({ ok: false, reason: "failed" }))]) {
    const h = harness({ record: { AnthropicAI: ["0"] }, fetch: { AnthropicAI: fetched([enPost(2, url), enPost(1, ja)]) } });
    setup(h);
    assert.equal(await run(h.deps), 0);
    assert.deepEqual(h.poster.received, [message(1, ja), message(2, url)]);
    assert.deepEqual(h.translator.calls, []);
    assert.deepEqual(h.lines, ["通知した件数: 2"]);
    assert.deepEqual(h.record.ids("AnthropicAI"), ["0", "1", "2"]);
  }
});

test("XPJA-5: 長い訳文は本文だけを切り詰め、機械翻訳の印と URL を残して上限に収める", async () => {
  const limit = 200;
  const long = `${"新しいモデルを公開します。".repeat(20)}`;
  const h = harness({ record: { AnthropicAI: ["0"] }, fetch: { AnthropicAI: fetched([enPost(1, EN)]) }, textLimit: limit });
  h.translator.set(EN, { ok: true, text: long });
  // 長さの検証（原文の 3 倍 + 200 文字以下）を通る長さにする
  assert.ok(Array.from(long).length <= EN.length * 3 + 200);
  assert.equal(await run(h.deps), 0);
  const sent = h.poster.received[0] ?? "";
  assert.ok(h.poster.measure(sent) <= limit);
  assert.ok(sent.endsWith(`…（長いため途中まで）\n${TRANSLATED}\nhttps://x.com/AnthropicAI/status/1`), sent);
});

test("XPJA-5: 翻訳に失敗した長い原文も、本文だけを切り詰め、失敗の印と URL を残す", async () => {
  const limit = 200;
  const long = "This is a long English post about our new model. ".repeat(10);
  const h = harness({ record: { AnthropicAI: ["0"] }, fetch: { AnthropicAI: fetched([enPost(1, long)]) }, textLimit: limit });
  h.translator.set(long, { ok: false, reason: "failed" });
  assert.equal(await run(h.deps), 0);
  const sent = h.poster.received[0] ?? "";
  assert.ok(h.poster.measure(sent) <= limit);
  assert.ok(sent.endsWith(`…（長いため途中まで）\n${FAILED}\nhttps://x.com/AnthropicAI/status/1`), sent);
});

test("XPJA-6: 翻訳の場面（訳せた・失敗した・使用量の上限）で、出力・通・記録・翻訳に渡した本文に秘匿値もトークンも無い", async () => {
  const scenes: ((h: Harness) => void)[] = [
    (h) => h.translator.set(EN, { ok: true, text: JA }),
    (h) => h.translator.set(EN, "throw"),
    (h) => h.translator.set(EN, { ok: false, reason: "unavailable" }),
  ];
  for (const scene of scenes) {
    const dir = await mkdtemp(join(tmpdir(), "x-dev-rss-test-"));
    const h = harness({ fetch: { AnthropicAI: fetched([enPost(1, EN)]) } });
    h.deps.record = createRecordFile(dir);
    scene(h);
    assert.equal(await run(h.deps), 0);
    assertNoLeaks(h);
    assert.deepEqual(h.translator.calls.map((c) => c.text), h.translator.calls.map(() => EN));
    for (const name of await readdir(dir)) {
      const text = await readFile(join(dir, name), "utf8");
      assert.ok(!containsSecret(text) && !text.includes(FAKE_TOKEN));
    }
    await rm(dir, { recursive: true });
  }
});

test("XPJA-7: 使用量の上限や契約のログインでないとき（unavailable）は失敗の扱いで終了コード 0。後のポストは訳さない", async () => {
  const other = "Another update from our team today.";
  const h = harness({ record: { AnthropicAI: ["0"] }, fetch: { AnthropicAI: fetched([enPost(2, other), enPost(1, EN)]) } });
  h.translator.fallback = () => ({ ok: false, reason: "unavailable" });
  assert.equal(await run(h.deps), 0);
  assert.deepEqual(h.poster.received, [message(1, EN, FAILED), message(2, other, FAILED)]);
  // 1 回目が unavailable なら 2 回目を試さず待たずに止める（D21）
  assert.equal(h.translator.calls.length, 1);
  assert.ok(!h.time.sleeps.includes(TRANSLATE_RETRY_DELAY_MS));
  assert.deepEqual(h.lines, ["翻訳に失敗したため原文のまま投稿したポストの件数: 2", "通知した件数: 2"]);
  assert.deepEqual(h.record.ids("AnthropicAI"), ["0", "1", "2"]);
});

test("XPJA-8: 2 件の英語のポストを古い順に訳して投稿・記録し、2 回目は「新しいポストはありません」の 1 通だけ", async () => {
  const a = "Introducing a new feature for developers.";
  const b = "Our research team published a new paper.";
  const h = harness({ record: { AnthropicAI: ["0"] }, fetch: { AnthropicAI: fetched([enPost(2, b), enPost(1, a), fakePost(0)]) } });
  h.translator.set(a, { ok: true, text: "開発者向けの新機能を紹介します。" });
  h.translator.set(b, { ok: true, text: "研究チームが新しい論文を公開しました。" });
  assert.equal(await run(h.deps), 0);
  assert.deepEqual(h.poster.received, [message(1, "開発者向けの新機能を紹介します。", TRANSLATED), message(2, "研究チームが新しい論文を公開しました。", TRANSLATED)]);
  assert.deepEqual(h.lines, ["通知した件数: 2"]);
  h.poster.received = [];
  h.lines.length = 0;
  assert.equal(await run(h.deps), 0);
  assert.deepEqual(h.poster.received, ["新しいポストはありません（確かめたアカウント: @AnthropicAI）"]);
  assert.deepEqual(h.lines, ["通知した件数: 0"]);
});

test("XPJA-9: 4 語以下で原文と同じ文字が返れば、1 回目で印なしの原文。2 回目を試さず、失敗の行が無く、記録される", async () => {
  for (const text of ["Claude Opus 5", "Claude Code for Teams", "Claude 5 の新機能 Opus Code Max"]) {
    const h = harness({ record: { AnthropicAI: ["0"] }, fetch: { AnthropicAI: fetched([enPost(1, text)]) } });
    h.translator.set(text, { ok: true, text });
    assert.equal(await run(h.deps), 0, text);
    assert.deepEqual(h.poster.received, [message(1, text)], text);
    assert.equal(h.translator.calls.length, 1, text);
    assert.deepEqual(h.time.sleeps, [], text);
    assert.deepEqual(h.lines, ["通知した件数: 1"], text);
    assert.deepEqual(h.record.ids("AnthropicAI"), ["0", "1"], text);
  }
});

test("XPJA-10: 5 語以上で原文と同じ文字が返ったときと、4 語以下で翻訳の手段が使えないときは、失敗の扱い", async () => {
  // 3 つ目は翻訳を呼ぶ回数（unavailable のときは 2 回目を試さない。D21）
  const scenes: [string, FakeTranslationLike, number][] = [
    ["Meet the new Claude model", { ok: true, text: "Meet the new Claude model" }, 2],
    ["新製品 Alpha, Beta, Gamma, Delta, Epsilon", { ok: true, text: "新製品 Alpha, Beta, Gamma, Delta, Epsilon" }, 2],
    ["Claude Opus 5", { ok: false, reason: "unavailable" }, 1],
    ["Claude Opus 5", { ok: false, reason: "failed" }, 2],
    ["Claude Opus 5", { ok: false, reason: "timeout" }, 2],
  ];
  for (const [text, result, callCount] of scenes) {
    const h = harness({ record: { AnthropicAI: ["0"] }, fetch: { AnthropicAI: fetched([enPost(1, text)]) } });
    h.translator.set(text, result);
    assert.equal(await run(h.deps), 0, text);
    assert.deepEqual(h.poster.received, [message(1, text, FAILED)], text);
    assert.equal(h.translator.calls.length, callCount, text);
    assert.deepEqual(h.lines, ["翻訳に失敗したため原文のまま投稿したポストの件数: 1", "通知した件数: 1"], text);
    assert.deepEqual(h.record.ids("AnthropicAI"), ["0", "1"], text);
  }
});

type FakeTranslationLike = Parameters<Harness["translator"]["set"]>[1];

// ---- 終了要求（D14） ----

test("D14: 訳の途中で終了要求の印が立つと、投稿も記録の書き込みも件数の行も行わずに戻り、ロックは外れる", async () => {
  let flag = false;
  const h = harness({ record: { AnthropicAI: ["0"] }, fetch: { AnthropicAI: fetched([enPost(2, "Second English post for today."), enPost(1, EN)]) } });
  h.deps.interrupted = () => flag;
  h.translator.onCall = () => {
    flag = true;
  };
  h.translator.set(EN, { ok: false, reason: "unavailable" });
  await run(h.deps);
  assert.deepEqual(h.poster.attempts, []);
  assert.deepEqual(h.record.writes, []);
  assert.deepEqual(h.lines, []);
  assert.equal(h.lock.released, 1);
});

test("D14: 印が立った後は、「新しいポストはありません」を投稿せず、次のアカウントの取得もしない", async () => {
  let flag = false;
  const h = harness({ accounts: ["AnthropicAI", "Q"], record: { AnthropicAI: ["1"], Q: ["2"] }, fetch: { AnthropicAI: fetched([fakePost(1)]), Q: fetched([fakePost(2)]) } });
  h.deps.interrupted = () => flag;
  const inner = h.fetcher.fetchAccount.bind(h.fetcher);
  h.fetcher.fetchAccount = async (account) => {
    const result = await inner(account);
    flag = true;
    return result;
  };
  await run(h.deps);
  assert.deepEqual(h.fetcher.calls, ["AnthropicAI"]);
  assert.deepEqual(h.poster.attempts, []);
  assert.deepEqual(h.lines, []);
});

test("D14: 投稿の送信中に印が立っても、送信を終えた投稿は記録し、次のポストは訳さず投稿もしない", async () => {
  let flag = false;
  const h = harness({ record: { AnthropicAI: ["0"] }, fetch: { AnthropicAI: fetched([enPost(2, JA), enPost(1, JA)]) } });
  h.deps.interrupted = () => flag;
  h.poster.fail = () => {
    flag = true;
    return undefined;
  };
  await run(h.deps);
  assert.deepEqual(postedIds(h), ["1"]);
  assert.deepEqual(h.record.ids("AnthropicAI"), ["0", "1"]);
  assert.equal(h.poster.attempts.length, 1);
  assert.deepEqual(h.lines, []);
});

test("D14: Slack の再試行の待ちの間に印が立つと、次の投稿の試行をせず、失敗の行も出さない", async () => {
  let flag = false;
  const h = harness({ record: { AnthropicAI: ["0"] }, fetch: { AnthropicAI: fetched([enPost(1, JA)]) } });
  h.deps.interrupted = () => flag;
  h.poster.fail = () => ({ ok: false, retryable: true });
  const sleep = h.deps.sleep;
  h.deps.sleep = async (ms) => {
    await sleep(ms);
    flag = true;
  };
  await run(h.deps);
  assert.equal(h.poster.attempts.length, 1);
  assert.deepEqual(h.record.writes, []);
  assert.deepEqual(h.lines, []);
});

test("D14: X の取得の再試行の待ちの間に印が立つと、次の取得の試行をせず、何も投稿しない", async () => {
  let flag = false;
  const h = harness({ fetch: { AnthropicAI: [fail("temporary"), fetched([fakePost(1)])] } });
  h.deps.interrupted = () => flag;
  const sleep = h.deps.sleep;
  h.deps.sleep = async (ms) => {
    await sleep(ms);
    flag = true;
  };
  await run(h.deps);
  assert.deepEqual(h.fetcher.calls, ["AnthropicAI"]);
  assert.deepEqual(h.poster.attempts, []);
  assert.deepEqual(h.lines, []);
});
