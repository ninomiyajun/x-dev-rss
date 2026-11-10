// Slack の Incoming Webhook への投稿（計画の手順 5・D7・D8）。
// 応答の本文と例外の文面は、どこにも出さない（失敗の種類だけを返す）。
import type { PostPort, PostResult, SecretBundle } from "../app/ports.ts";
import { openBundle } from "./secrets.ts";

/** 1 通の text の上限（D7）。 */
export const SLACK_TEXT_LIMIT = 40000;
const TIMEOUT_MS = 15000;

/** Slack の mrkdwn で特別な意味を持つ 3 つの文字を書き換える。 */
export function escapeForSlack(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function retryAfterSeconds(value: string | null): number | undefined {
  if (value === null || !/^[0-9]+$/.test(value.trim())) return undefined;
  return Number(value.trim());
}

export type SlackOptions = { fetch?: typeof fetch; timeoutMs?: number };

export function createSlackPoster(bundle: SecretBundle, options: SlackOptions = {}): PostPort {
  const doFetch = options.fetch ?? fetch;
  const timeoutMs = options.timeoutMs ?? TIMEOUT_MS;
  return {
    textLimit: SLACK_TEXT_LIMIT,
    measure: (text) => escapeForSlack(text).length,
    async post(text): Promise<PostResult> {
      const { webhookUrl } = openBundle(bundle);
      let res: Response;
      try {
        res = await doFetch(webhookUrl, {
          method: "POST",
          // 転送先へ本文を送らない（Webhook の URL 以外へ通知の中身を渡さないため）。
          redirect: "error",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ text: escapeForSlack(text) }),
          signal: AbortSignal.timeout(timeoutMs),
        });
      } catch {
        // TypeError（通信の失敗）と打ち切りは一時的な失敗。
        return { ok: false, retryable: true };
      }
      // 応答の本文は読まずに捨てる（出さないため）。
      await res.body?.cancel().catch(() => undefined);
      if (res.status === 200) return { ok: true };
      if (res.status === 429) {
        // Retry-After が無ければ 5 秒（D8）。
        return { ok: false, retryable: true, retryAfterSeconds: retryAfterSeconds(res.headers.get("retry-after")) ?? 5 };
      }
      if (res.status >= 500) return { ok: false, retryable: true };
      return { ok: false, retryable: false };
    },
  };
}
