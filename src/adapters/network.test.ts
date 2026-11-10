// 外へ通信する外との接続（X の取得・Slack の投稿）の試験。fetch とライブラリは偽物に差し替え、本物の X と Slack へは要求しない。
import { test } from "node:test";
import assert from "node:assert/strict";
import { ApiError, AuthenticationError } from "@the-convocation/twitter-scraper";
import type { Tweet } from "@the-convocation/twitter-scraper";
import { makeBundle } from "./secrets.ts";
import { createSlackPoster, escapeForSlack, SLACK_TEXT_LIMIT } from "./slack-webhook.ts";
import {
  classifyError,
  createXFetcher,
  guardedFetch,
  inspectTimelineBody,
  newGuardState,
  TIMELINE,
  toFacts,
  unescapeHtml,
} from "./x-scraper.ts";
import type { ScraperLike } from "./x-scraper.ts";
import { containsSecret, FAKE_SECRETS } from "../app/fakes.ts";

const bundle = makeBundle({
  username: FAKE_SECRETS.X_USERNAME,
  authToken: FAKE_SECRETS.X_AUTH_TOKEN,
  ct0: FAKE_SECRETS.X_CT0,
  webhookUrl: FAKE_SECRETS.SLACK_WEBHOOK_URL,
});

type Call = { url: string; init: RequestInit | undefined };

function fakeFetch(respond: (url: string, n: number) => Response | Promise<Response>): { fetch: typeof fetch; calls: Call[] } {
  const calls: Call[] = [];
  const f = (async (input: Parameters<typeof fetch>[0], init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    calls.push({ url, init });
    return respond(url, calls.length);
  }) as typeof fetch;
  return { fetch: f, calls };
}

// ---- Slack ----

test("Slack: & < > を書き換えて {text} を POST し、200 を成功にする", async () => {
  const { fetch, calls } = fakeFetch(() => new Response("ok", { status: 200 }));
  const poster = createSlackPoster(bundle, { fetch });
  assert.deepEqual(await poster.post("a & <b>"), { ok: true });
  assert.equal(calls[0]?.url, FAKE_SECRETS.SLACK_WEBHOOK_URL);
  assert.equal(calls[0]?.init?.method, "POST");
  assert.deepEqual(JSON.parse(String(calls[0]?.init?.body)), { text: "a &amp; &lt;b&gt;" });
  assert.equal(poster.textLimit, SLACK_TEXT_LIMIT);
  assert.equal(poster.measure("<&>"), escapeForSlack("<&>").length);
});

test("Slack: 429 は Retry-After の秒数付き、5xx と通信の失敗は一時的、ほかの 4xx は一時的でない", async () => {
  const cases: [() => Response | Promise<Response>, unknown][] = [
    [() => new Response("", { status: 429, headers: { "retry-after": "7" } }), { ok: false, retryable: true, retryAfterSeconds: 7 }],
    [() => new Response("", { status: 429 }), { ok: false, retryable: true, retryAfterSeconds: 5 }],
    [() => new Response("x", { status: 503 }), { ok: false, retryable: true }],
    [() => new Response(`invalid ${FAKE_SECRETS.SLACK_WEBHOOK_URL}`, { status: 404 }), { ok: false, retryable: false }],
    [
      () => {
        throw new TypeError(`fetch failed ${FAKE_SECRETS.SLACK_WEBHOOK_URL}`);
      },
      { ok: false, retryable: true },
    ],
  ];
  for (const [respond, expected] of cases) {
    const poster = createSlackPoster(bundle, { fetch: fakeFetch(respond).fetch });
    const result = await poster.post("本文");
    assert.deepEqual(result, expected);
    assert.ok(!containsSecret(JSON.stringify(result)));
  }
});

test("Slack: 応答が来なければ打ち切って一時的な失敗にする", async () => {
  const never = (async (_input: unknown, init?: RequestInit) =>
    new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => reject(init.signal?.reason));
    })) as typeof fetch;
  const poster = createSlackPoster(bundle, { fetch: never, timeoutMs: 20 });
  assert.deepEqual(await poster.post("本文"), { ok: false, retryable: true });
});

// ---- X: fetch の包みと異常な応答（D12） ----

const timelineBody = (instructions: unknown[] | undefined, errors?: unknown[]) =>
  JSON.stringify({
    ...(instructions === undefined ? {} : { data: { user: { result: { __typename: "User", timeline: { timeline: { instructions } } } } } }),
    ...(errors === undefined ? {} : { errors }),
  });

test("D12: instructions があれば errors があっても異常にしない。無ければ errors の有無で分ける", () => {
  assert.equal(inspectTimelineBody(timelineBody([])), undefined);
  assert.equal(inspectTimelineBody(timelineBody([], [{ message: "partial" }])), undefined);
  assert.deepEqual(inspectTimelineBody(timelineBody(undefined, [{ message: "x" }])), { kind: "abnormal", retryable: false });
  assert.deepEqual(inspectTimelineBody(timelineBody(undefined)), { kind: "abnormal", retryable: true });
  assert.deepEqual(inspectTimelineBody("<html>"), { kind: "abnormal", retryable: true });
  assert.deepEqual(inspectTimelineBody(JSON.stringify({ data: { user: { result: { __typename: "UserUnavailable" } } } })), {
    kind: "target-unavailable",
    retryable: false,
  });
});

test("D5: fetch の包みは要求を数え、タイムラインの 5 回目を X へ送らずに拒む", async () => {
  const { fetch, calls } = fakeFetch(() => new Response(timelineBody([]), { status: 200 }));
  const state = newGuardState();
  const wrapped = guardedFetch(fetch, () => state);
  await wrapped("https://x.com/i/api/graphql/abc/UserByScreenName?x=1");
  for (let i = 0; i < TIMELINE.requestLimit; i++) await wrapped(`https://x.com/i/api/graphql/abc/${TIMELINE.endpoint}?x=1`);
  await assert.rejects(wrapped(`https://x.com/i/api/graphql/abc/${TIMELINE.endpoint}?x=1`));
  assert.equal(calls.length, 5);
  assert.deepEqual([state.requests, state.timelineRequests, state.abnormal], [5, 4, undefined]);
  assert.ok(calls.every((c) => c.init?.signal instanceof AbortSignal));
});

// ---- X: 中立な事実への写し ----

function tweet(id: string, extra: Partial<Tweet> = {}): Tweet {
  return {
    id,
    userId: "100",
    username: "AnthropicAI",
    hashtags: [],
    mentions: [],
    photos: [],
    thread: [],
    urls: [],
    videos: [],
    text: `本文 ${id}`,
    permanentUrl: `https://x.com/AnthropicAI/status/${id}`,
    ...extra,
  };
}

test("XPOST-6: ライブラリのポストを中立な事実へ写す（種類・固定表示・日時・HTML 実体の戻し）", () => {
  const t = tweet("123", {
    isQuoted: true,
    isReply: true,
    isPin: true,
    timeParsed: new Date("2026-11-09T01:30:00Z"),
    text: "a &amp;lt; &lt;b&gt; &amp; c",
  });
  assert.deepEqual(toFacts(t, "AnthropicAI"), {
    id: "123",
    authorId: "100",
    authorName: "AnthropicAI",
    isRetweet: false,
    isQuote: true,
    isReply: true,
    isPinned: true,
    postedAt: new Date("2026-11-09T01:30:00Z"),
    text: "a &lt; <b> & c",
    url: "https://x.com/AnthropicAI/status/123",
  });
  assert.equal(unescapeHtml("&amp;gt;"), "&gt;");
  assert.equal(toFacts(tweet("12a"), "AnthropicAI"), undefined);
  assert.equal(toFacts(tweet("5", { isRetweet: true, timeParsed: undefined }), "A")?.postedAt, undefined);
});

// ---- X: 失敗の分け方（D10・XPOST-22） ----

test("XPOST-22: 401・403 の ApiError と AuthenticationError はログインの拒否で、やり直さない", () => {
  const headers = { "set-cookie": `auth_token=${FAKE_SECRETS.X_AUTH_TOKEN}` };
  for (const status of [401, 403]) {
    const err = new ApiError(new Response("", { status, headers }), { secret: FAKE_SECRETS.X_CT0 });
    assert.ok(err.message.includes(FAKE_SECRETS.X_AUTH_TOKEN), "ライブラリの文面には値が入る（だから出さない）");
    assert.deepEqual(classifyError(err, "profile"), { kind: "login-rejected", retryable: false });
  }
  assert.deepEqual(classifyError(new AuthenticationError(), "profile"), { kind: "login-rejected", retryable: false });
});

test("D10: 凍結などは対象のアカウントの失敗で、ログインの拒否に分けない。429・5xx・通信の失敗も分ける", () => {
  for (const message of ["User is suspended.", "User not found.", "User x does not exist or is private."]) {
    assert.deepEqual(classifyError(new Error(message), "profile"), { kind: "target-unavailable", retryable: false });
  }
  assert.deepEqual(classifyError(new ApiError(new Response("", { status: 429 }), ""), "timeline"), {
    kind: "rate-limited",
    retryable: false,
  });
  assert.deepEqual(classifyError(new ApiError(new Response("", { status: 502 }), ""), "timeline"), {
    kind: "temporary",
    retryable: true,
  });
  assert.deepEqual(classifyError(new TypeError("fetch failed"), "timeline"), { kind: "temporary", retryable: true });
  assert.deepEqual(classifyError(new DOMException("t", "TimeoutError"), "timeline"), { kind: "temporary", retryable: true });
  assert.deepEqual(classifyError(new Error("x"), "timeline"), { kind: "other", retryable: false });
});

// ---- X: 取得の流れ（ライブラリを偽物に差し替える） ----

test("D5: 取得の定義は 1 か所で、呼ぶメソッドと見張るエンドポイントが対になっている", async () => {
  assert.equal(TIMELINE.endpoint, "UserTweets");
  const calls: string[] = [];
  const s: ScraperLike = {
    async setCookies() {},
    async getUserIdByScreenName() {
      return "1";
    },
    // eslint-disable-next-line require-yield
    async *getTweets(user, max) {
      calls.push(`getTweets ${user} ${max}`);
    },
  };
  for await (const _ of TIMELINE.read(s, "A")) void _;
  assert.deepEqual(calls, [`getTweets A ${TIMELINE.receivedLimit}`]);
  // 似た名前のエンドポイント（返信を含むもの）は数えない
  const { fetch } = fakeFetch(() => new Response(timelineBody([]), { status: 200 }));
  const state = newGuardState();
  await guardedFetch(fetch, () => state)("https://x.com/i/api/graphql/abc/UserTweetsAndReplies?x=1");
  assert.equal(state.timelineRequests, 0);
});

const TIMELINE_URL = `https://x.com/i/api/graphql/abc/${TIMELINE.endpoint}?v=1`;

/** ページごとに wrapped fetch でタイムラインの要求を 1 回送り、そのページのポストを返す偽物の Scraper。 */
function fakeScraper(pages: Tweet[][], opts: { body?: (page: number) => string; profileError?: unknown; cookieError?: unknown } = {}) {
  const log = { cookies: [] as string[], pagesRequested: 0 };
  const create = (wrapped: typeof fetch): ScraperLike => ({
    async setCookies(cookies) {
      if (opts.cookieError !== undefined) throw opts.cookieError;
      log.cookies = cookies;
    },
    async getUserIdByScreenName() {
      await wrapped("https://x.com/i/api/graphql/abc/UserByScreenName?v=1");
      if (opts.profileError !== undefined) throw opts.profileError;
      return "100";
    },
    async *getTweets() {
      for (let i = 0; ; i++) {
        await wrapped(TIMELINE_URL);
        log.pagesRequested++;
        const page = pages[i] ?? [];
        if (page.length === 0) return;
        for (const t of page) yield t;
      }
    },
  });
  return { create, log };
}

function fetcherFor(pages: Tweet[][], opts: { body?: (page: number) => string; profileError?: unknown; cookieError?: unknown } = {}) {
  const scraper = fakeScraper(pages, opts);
  let page = 0;
  const { fetch, calls } = fakeFetch((url) => {
    if (url === TIMELINE_URL) return new Response(opts.body?.(page++) ?? timelineBody([]), { status: 200 });
    return new Response("{}", { status: 200 });
  });
  return { fetcher: createXFetcher(bundle, { fetch, createScraper: scraper.create }), log: scraper.log, calls };
}

function success(result: Awaited<ReturnType<ReturnType<typeof createXFetcher>["fetchAccount"]>>) {
  assert.ok(result.ok);
  return result as Extract<typeof result, { ok: true }>;
}

test("取得: Cookie を 2 つ渡し、並びの終わりまで読んだら exhausted。ID で重複を除く", async () => {
  const { fetcher, log } = fetcherFor([[tweet("3"), tweet("2")], [tweet("2"), tweet("1")]]);
  const result = success(await fetcher.fetchAccount("AnthropicAI"));
  assert.deepEqual(log.cookies, [`auth_token=${FAKE_SECRETS.X_AUTH_TOKEN}`, `ct0=${FAKE_SECRETS.X_CT0}`]);
  assert.deepEqual(result.posts.map((p) => p.id), ["3", "2", "1"]);
  assert.equal(result.stop, "exhausted");
  assert.equal(result.requests, 4); // 利用者の ID の 1 回と、タイムラインの 3 回（最後は空のページ）
});

test("XPOST-5: 20 件そろってもページは読み切り、次のページは X へ送らずに止める", async () => {
  const page1: Tweet[] = [tweet("999", { isPin: true })];
  for (let i = 1; i <= 30; i++) {
    page1.push(tweet(String(500 - i)));
    if (i % 3 === 0) page1.push(tweet(String(800 + i), { isRetweet: true }), tweet(String(900 + i), { isQuoted: true }));
  }
  const { fetcher, log, calls } = fetcherFor([page1, [tweet("1")]]);
  const result = success(await fetcher.fetchAccount("AnthropicAI"));
  assert.equal(result.stop, "enough");
  assert.equal(log.pagesRequested, 1);
  assert.equal(calls.filter((c) => c.url === TIMELINE_URL).length, 1);
  assert.equal(result.posts.length, page1.length); // ページの 51 件をすべて読んだ
});

test("XPOST-5: 1 ページの中が順不同でも、ID の大きい順の 20 位以内が欠けない", async () => {
  const ids = Array.from({ length: 30 }, (_, i) => 1000 + i);
  // 古いものを先に、新しいものを後に並べる（順不同）
  const page1 = [...ids].sort((a, b) => ((a * 37) % 30) - ((b * 37) % 30)).map((id) => tweet(String(id)));
  // 20 件目を数えた時点では、まだ届いていない 20 位以内のポストがある並びであることを確かめておく
  const firstTwenty = new Set(page1.slice(0, 20).map((t) => t.id));
  assert.ok(Array.from({ length: 20 }, (_, i) => String(1010 + i)).some((id) => !firstTwenty.has(id)));
  const { fetcher } = fetcherFor([page1, [tweet("1")]]);
  const result = success(await fetcher.fetchAccount("AnthropicAI"));
  assert.equal(result.stop, "enough");
  const got = new Set(result.posts.map((p) => p.id));
  for (let id = 1010; id < 1030; id++) assert.ok(got.has(String(id)), String(id));
});

test("XPOST-20 / D5: タイムラインの要求が上限に達したら limit で止め、それまでのポストで続ける", async () => {
  const pages: Tweet[][] = [];
  for (let p = 0; p < 6; p++) pages.push([tweet(String(100 + p), { isRetweet: true })]);
  const { fetcher, log } = fetcherFor(pages);
  const result = success(await fetcher.fetchAccount("AnthropicAI"));
  assert.equal(result.stop, "limit");
  assert.equal(log.pagesRequested, TIMELINE.requestLimit);
  assert.equal(result.posts.length, 4);
  assert.equal(result.requests, 5);
});

test("D12: 異常な応答の回は、受け取った並びを捨てて失敗にする", async () => {
  const { fetcher } = fetcherFor([[tweet("1")]], { body: () => timelineBody(undefined, [{ message: "x" }]) });
  const result = await fetcher.fetchAccount("AnthropicAI");
  assert.deepEqual(result, { ok: false, kind: "abnormal", retryable: false, requests: 2 });
});

test("XPOST-7 / XPOST-22: 利用者の ID を引く段の失敗を種類に分け、結果に秘匿値も原文も入れない", async () => {
  const err = new ApiError(new Response("", { status: 401, headers: { "set-cookie": `ct0=${FAKE_SECRETS.X_CT0}` } }), FAKE_SECRETS.X_AUTH_TOKEN);
  const { fetcher } = fetcherFor([], { profileError: err });
  const result = await fetcher.fetchAccount("AnthropicAI");
  assert.deepEqual(result, { ok: false, kind: "login-rejected", retryable: false, requests: 1 });
  const suspended = fetcherFor([], { profileError: new Error("User is suspended.") });
  assert.deepEqual(await suspended.fetcher.fetchAccount("A"), { ok: false, kind: "target-unavailable", retryable: false, requests: 1 });
});

test("D10: 利用者の ID を引く段の素の Error は、決まった文に一致しなければ凍結と取り違えず「そのほか」。Cookie を渡す段の失敗も「そのほか」", async () => {
  const other = fetcherFor([], { profileError: new Error("rest_id not found.") });
  assert.deepEqual(await other.fetcher.fetchAccount("A"), { ok: false, kind: "other", retryable: false, requests: 1 });
  const cookie = fetcherFor([], { cookieError: new Error("User is suspended.") });
  assert.deepEqual(await cookie.fetcher.fetchAccount("A"), { ok: false, kind: "other", retryable: false, requests: 0 });
  assert.deepEqual(classifyError(new Error("User is suspended."), "timeline"), { kind: "other", retryable: false });
});

test("D14: ID が 10 進数の文字列でないポストがあれば、その回は「そのほか」の失敗", async () => {
  const { fetcher } = fetcherFor([[tweet("1"), tweet("x1")]]);
  const result = await fetcher.fetchAccount("AnthropicAI");
  assert.deepEqual(result, { ok: false, kind: "other", retryable: false, requests: 2 });
});

test("V8: Slack への fetch は転送を追わない（redirect: error）", async () => {
  const { fetch, calls } = fakeFetch(() => new Response("ok", { status: 200 }));
  await createSlackPoster(bundle, { fetch }).post("本文");
  assert.equal(calls[0]?.init?.redirect, "error");
});

// ---- X: 本物の Scraper と差し替えた fetch ----

test("XPOST-5: 本物の Scraper でも、1 ページで通常のポストが 20 件そろえば 2 ページ目を要求せず、止めたことを失敗にしない", async () => {
  const account = "RealScraperCheck";
  const userId = "4242";
  const entry = (id: number) => ({
    entryId: `tweet-${id}`,
    sortIndex: String(id),
    content: {
      entryType: "TimelineTimelineItem",
      itemContent: {
        itemType: "TimelineTweet",
        tweet_results: {
          result: {
            __typename: "Tweet",
            rest_id: String(id),
            core: { user_results: { result: { rest_id: userId, legacy: { screen_name: account, name: "Check" } } } },
            legacy: {
              id_str: String(id),
              full_text: `post ${id}`,
              user_id_str: userId,
              created_at: "Mon Nov 09 01:00:00 +0000 2026",
              conversation_id_str: String(id),
              entities: { hashtags: [], urls: [], user_mentions: [], symbols: [] },
            },
          },
        },
      },
    },
  });
  const ids = Array.from({ length: 22 }, (_, i) => 1000 - i);
  const page = JSON.stringify({
    data: {
      user: {
        result: {
          __typename: "User",
          timeline: {
            timeline: {
              instructions: [
                {
                  type: "TimelineAddEntries",
                  entries: [...ids.map(entry), { entryId: "cursor-bottom-1", content: { entryType: "TimelineTimelineCursor", cursorType: "Bottom", value: "next-page" } }],
                },
              ],
            },
          },
        },
      },
    },
  });
  const profile = JSON.stringify({
    data: { user: { result: { __typename: "User", rest_id: userId, legacy: { screen_name: account, name: "Check" }, core: { screen_name: account, name: "Check" } } } },
  });
  const { fetch, calls } = fakeFetch((url) => {
    if (new URL(url).pathname.endsWith("/UserByScreenName")) return new Response(profile, { status: 200 });
    if (new URL(url).pathname.endsWith(`/${TIMELINE.endpoint}`)) return new Response(page, { status: 200 });
    return new Response("{}", { status: 200 });
  });
  // 差し替えた fetch を通らない要求があれば失敗にする（本物の X へは送らない）。
  // ただし止めるのは globalThis.fetch だけで、ライブラリが既定で使う通信（cross-fetch）は止めない。
  // 本物の X へ送らないことは、Scraper に差し替えた fetch を渡し、その呼び出しの数を数えることで確かめている。
  const original = globalThis.fetch;
  globalThis.fetch = (async () => {
    throw new Error("unexpected network request");
  }) as typeof fetch;
  let outcome;
  try {
    outcome = await createXFetcher(bundle, { fetch }).fetchAccount(account);
  } finally {
    globalThis.fetch = original;
  }
  const result = success(outcome);
  assert.equal(result.stop, "enough");
  assert.equal(result.targetUserId, userId);
  assert.deepEqual(result.posts.map((p) => p.id), ids.map(String));
  assert.equal(calls.filter((c) => new URL(c.url).pathname.endsWith(`/${TIMELINE.endpoint}`)).length, 1);
  assert.ok(calls.every((c) => new URL(c.url).hostname.endsWith("x.com") || new URL(c.url).hostname.endsWith("twitter.com")));
});
