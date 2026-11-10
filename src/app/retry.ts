// やり直しと投稿の間隔（計画の D8）。待ちと時刻は口を通す。
import type { Clock, FetchResult, PostPort, PostResult, Sleep } from "./ports.ts";

/** 一時的な失敗のあとの待ち（1 回目・2 回目のやり直しの前）。 */
export const RETRY_DELAYS_MS = [5000, 15000] as const;
/** 投稿の口の呼び出しの間に空ける長さ。 */
export const POST_INTERVAL_MS = 1100;
/** これより長い Retry-After は待たずに失敗にする。 */
export const MAX_RETRY_AFTER_SECONDS = 60;

/** X の取得を、一時的な失敗のときだけ 2 回までやり直す。 */
export async function fetchWithRetry(attempt: () => Promise<FetchResult>, sleep: Sleep): Promise<FetchResult> {
  let result = await attempt();
  for (const delay of RETRY_DELAYS_MS) {
    if (result.ok || !result.retryable) return result;
    await sleep(delay);
    result = await attempt();
  }
  return result;
}

/** 投稿の口を包み、呼び出しの間隔を守り、一時的な失敗と 429 をやり直す。 */
export class PacedPoster {
  private lastCall: number | undefined;
  private readonly inner: PostPort;
  private readonly sleep: Sleep;
  private readonly now: Clock;

  constructor(inner: PostPort, sleep: Sleep, now: Clock) {
    this.inner = inner;
    this.sleep = sleep;
    this.now = now;
  }

  get textLimit(): number {
    return this.inner.textLimit;
  }

  measure(text: string): number {
    return this.inner.measure(text);
  }

  private async callOnce(text: string): Promise<PostResult> {
    if (this.lastCall !== undefined) {
      const wait = POST_INTERVAL_MS - (this.now() - this.lastCall);
      if (wait > 0) await this.sleep(wait);
    }
    try {
      return await this.inner.post(text);
    } finally {
      this.lastCall = this.now();
    }
  }

  async post(text: string): Promise<PostResult> {
    let result = await this.callOnce(text);
    for (const delay of RETRY_DELAYS_MS) {
      if (result.ok || !result.retryable) return result;
      if (result.retryAfterSeconds !== undefined) {
        if (result.retryAfterSeconds > MAX_RETRY_AFTER_SECONDS) return result;
        await this.sleep(result.retryAfterSeconds * 1000);
      } else {
        await this.sleep(delay);
      }
      result = await this.callOnce(text);
    }
    return result;
  }
}
