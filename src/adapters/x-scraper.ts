// X からの取得（計画の手順 5・D5・D10・D12・D14）。取得のライブラリを読み込んでよいのは、このファイルだけである。
// ライブラリの例外の文面（応答のヘッダーと本文が入る）は、どこにも出さない（失敗の種類だけを返す）。
import { ApiError, AuthenticationError, ErrorRateLimitStrategy, Scraper } from "@the-convocation/twitter-scraper";
import type { Tweet } from "@the-convocation/twitter-scraper";
import type { FetchPort, FetchResult, SecretBundle } from "../app/ports.ts";
import type { FetchFailureKind } from "../domain/message.ts";
import { isDecimalId } from "../domain/post.ts";
import type { PostFacts } from "../domain/post.ts";
import { TimelineCollector } from "../domain/select.ts";
import type { StopReason } from "../domain/select.ts";
import { openBundle } from "./secrets.ts";

const TIMEOUT_MS = 30000;

/** このファイルが使う、ライブラリの Scraper の機能。試験では偽物に差し替える。 */
export type ScraperLike = {
  setCookies(cookies: string[]): Promise<void>;
  getUserIdByScreenName(screenName: string): Promise<string>;
  getTweets(user: string, maxTweets?: number): AsyncGenerator<Tweet>;
};

/** 異常な応答（D12）。 */
type Abnormal = { kind: FetchFailureKind; retryable: boolean };

/** タイムラインの応答の本文から、異常な応答を見分ける（D12）。異常でなければ undefined。 */
export function inspectTimelineBody(text: string): Abnormal | undefined {
  let data: unknown;
  try {
    data = JSON.parse(text);
  } catch {
    return { kind: "abnormal", retryable: true };
  }
  const root = (typeof data === "object" && data !== null ? data : {}) as Record<string, unknown>;
  const result = (root.data as { user?: { result?: Record<string, unknown> } } | undefined)?.user?.result;
  if (result?.__typename === "UserUnavailable") return { kind: "target-unavailable", retryable: false };
  const timeline = (result?.timeline as { timeline?: { instructions?: unknown } } | undefined)?.timeline;
  if (Array.isArray(timeline?.instructions)) return undefined;
  const errors = root.errors;
  if (Array.isArray(errors) && errors.length > 0) return { kind: "abnormal", retryable: false };
  return { kind: "abnormal", retryable: true };
}

/**
 * 取得に使うタイムラインの 1 か所の定義（D5）。呼ぶメソッド、見張るエンドポイントの名前、要求と件数の上限、
 * 応答の検査を一緒に持ち、片方だけを替えられないようにする。
 */
export const TIMELINE = {
  /** fetch の包みが見張る、URL のパスの最後の名前（read が呼ぶメソッドが使うもの）。 */
  endpoint: "UserTweets",
  /** タイムラインの要求の上限。次の要求は X へ送らずに拒む。 */
  requestLimit: 4,
  /** 受け取るポストの上限。 */
  receivedLimit: 200,
  read(scraper: ScraperLike, account: string): AsyncGenerator<Tweet> {
    return scraper.getTweets(account, TIMELINE.receivedLimit);
  },
  inspect: inspectTimelineBody,
} as const;

/** 次のタイムラインの要求を送らずに止めたことを示す目印の例外（このファイルの中だけで使う）。 */
class TimelineStop extends Error {
  readonly reason: "enough" | "limit";
  constructor(reason: "enough" | "limit") {
    super(`timeline stop: ${reason}`);
    this.reason = reason;
  }
}

/** 1 回の取得（1 アカウント・1 回の試み）の中で、fetch の包みが数え、見つけたもの。 */
export type GuardState = {
  requests: number;
  timelineRequests: number;
  abnormal: Abnormal | undefined;
  /** 集め役が 20 件そろったと言った後は、次のタイムラインの要求を送らない。 */
  stopRequested: boolean;
};

export function newGuardState(): GuardState {
  return { requests: 0, timelineRequests: 0, abnormal: undefined, stopRequested: false };
}

function urlOf(input: Parameters<typeof fetch>[0]): string {
  if (typeof input === "string") return input;
  if (input instanceof URL) return input.href;
  return input.url;
}

function isTimelineUrl(url: string): boolean {
  try {
    return new URL(url).pathname.endsWith(`/${TIMELINE.endpoint}`);
  } catch {
    return false;
  }
}

/**
 * ライブラリに渡す fetch の包み: 要求を打ち切り、回数を数え、止めると決めた後と上限を超える
 * タイムラインの要求を拒み、タイムラインの応答を clone して異常を確かめる。state は呼ぶ側が試みごとに差し替える。
 */
export function guardedFetch(base: typeof fetch, getState: () => GuardState, timeoutMs = TIMEOUT_MS): typeof fetch {
  return async (input, init) => {
    const state = getState();
    const isTimeline = isTimelineUrl(urlOf(input));
    if (isTimeline) {
      if (state.stopRequested) throw new TimelineStop("enough");
      if (state.timelineRequests >= TIMELINE.requestLimit) throw new TimelineStop("limit");
      state.timelineRequests++;
    }
    state.requests++;
    const res = await base(input, { ...init, signal: AbortSignal.timeout(timeoutMs) });
    if (isTimeline && res.ok && state.abnormal === undefined) {
      state.abnormal = TIMELINE.inspect(await res.clone().text());
    }
    return res;
  };
}

/** 本文の HTML 実体を戻す（X は &amp; などのまま届ける）。 */
export function unescapeHtml(text: string): string {
  return text.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
}

/** ライブラリのポストを中立な事実へ写す。ID が 10 進数の文字列でなければ undefined。 */
export function toFacts(tweet: Tweet, account: string): PostFacts | undefined {
  const id = tweet.id;
  if (typeof id !== "string" || !isDecimalId(id)) return undefined;
  const postedAt = tweet.timeParsed instanceof Date && !Number.isNaN(tweet.timeParsed.getTime()) ? tweet.timeParsed : undefined;
  return {
    id,
    authorId: tweet.userId,
    authorName: tweet.username,
    isRetweet: tweet.isRetweet === true,
    isQuote: tweet.isQuoted === true,
    isReply: tweet.isReply === true,
    isPinned: tweet.isPin === true,
    postedAt,
    text: unescapeHtml(tweet.text ?? ""),
    url: tweet.permanentUrl ?? `https://x.com/${account}/status/${id}`,
  };
}

/** 対象のアカウントの凍結・存在しない・非公開を表す、ライブラリの決まった文（発見の F6）。 */
const TARGET_UNAVAILABLE_MESSAGES = [/^User is suspended\.$/, /^User not found\.$/, /^User \S+ does not exist or is private\.$/];

/** 取得のどの段の失敗か。cookies: Cookie を渡す段、profile: 利用者の ID を引く段、timeline: 並びを読む段。 */
export type Phase = "cookies" | "profile" | "timeline";

/** ライブラリの例外を、失敗の種類に分ける（D10）。 */
export function classifyError(err: unknown, phase: Phase): { kind: FetchFailureKind; retryable: boolean } {
  if (phase === "cookies") return { kind: "other", retryable: false };
  if (err instanceof AuthenticationError) return { kind: "login-rejected", retryable: false };
  if (err instanceof ApiError) {
    const status = err.response?.status;
    if (status === 401 || status === 403) return { kind: "login-rejected", retryable: false };
    if (status === 429) return { kind: "rate-limited", retryable: false };
    if (typeof status === "number" && status >= 500) return { kind: "temporary", retryable: true };
    return { kind: "other", retryable: false };
  }
  if (err instanceof TypeError) return { kind: "temporary", retryable: true };
  if (err instanceof DOMException && (err.name === "TimeoutError" || err.name === "AbortError")) {
    return { kind: "temporary", retryable: true };
  }
  // 利用者の ID を引く段の素の Error のうち、決まった文に一致するものだけを、対象のアカウントの失敗にする。
  if (
    phase === "profile" &&
    err instanceof Error &&
    err.constructor === Error &&
    TARGET_UNAVAILABLE_MESSAGES.some((re) => re.test(err.message))
  ) {
    return { kind: "target-unavailable", retryable: false };
  }
  return { kind: "other", retryable: false };
}

export type XFetcherOptions = {
  fetch?: typeof fetch;
  createScraper?: (wrappedFetch: typeof fetch) => ScraperLike;
  timeoutMs?: number;
};

export function createXFetcher(bundle: SecretBundle, options: XFetcherOptions = {}): FetchPort {
  let state = newGuardState();
  const wrapped = guardedFetch(options.fetch ?? fetch, () => state, options.timeoutMs);
  const create =
    options.createScraper ??
    ((f: typeof fetch) => new Scraper({ fetch: f, rateLimitStrategy: new ErrorRateLimitStrategy() }) as unknown as ScraperLike);
  let scraper: ScraperLike | undefined;

  /** Cookie を渡した Scraper を作る（X へは要求しない）。 */
  async function withCookies(): Promise<ScraperLike> {
    if (scraper === undefined) {
      const { authToken, ct0 } = openBundle(bundle);
      const s = create(wrapped);
      await s.setCookies([`auth_token=${authToken}`, `ct0=${ct0}`]);
      scraper = s;
    }
    return scraper;
  }

  return {
    async fetchAccount(account): Promise<FetchResult> {
      state = newGuardState();
      const current = state;
      const fail = (f: { kind: FetchFailureKind; retryable: boolean }): FetchResult => ({ ok: false, ...f, requests: current.requests });
      let phase: Phase = "cookies";
      try {
        const s = await withCookies();
        phase = "profile";
        const targetUserId = await s.getUserIdByScreenName(account);
        phase = "timeline";
        const collector = new TimelineCollector(targetUserId);
        let received = 0;
        let stop: StopReason = "exhausted";
        try {
          for await (const tweet of TIMELINE.read(s, account)) {
            if (current.abnormal !== undefined) break;
            received++;
            const facts = toFacts(tweet, account);
            if (facts === undefined) return fail({ kind: "other", retryable: false });
            collector.add(facts);
            // そろってもページは読み切る。次のページの要求は fetch の包みが拒む。
            if (collector.enough) current.stopRequested = true;
          }
        } catch (err) {
          if (!(err instanceof TimelineStop)) throw err;
          stop = err.reason;
        }
        if (current.abnormal !== undefined) return fail(current.abnormal);
        if (stop === "exhausted" && received >= TIMELINE.receivedLimit) stop = collector.enough ? "enough" : "limit";
        return { ok: true, targetUserId, posts: collector.collected(), stop, requests: current.requests };
      } catch (err) {
        return fail(classifyError(err, phase));
      }
    },
  };
}
