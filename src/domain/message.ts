// 通の文面（Slack の書き換えの前の素の文）と、出力の行の文面（計画の D7・D10）。入出力を持たない。
import { postedAtOf } from "./post.ts";
import type { PostFacts } from "./post.ts";

/** 取得の失敗の種類（D10）。 */
export type FetchFailureKind = "login-rejected" | "target-unavailable" | "rate-limited" | "temporary" | "abnormal" | "other";

const FAILURE_TEXT: Record<FetchFailureKind, string> = {
  "login-rejected": "取得用のアカウントのログインが拒まれました",
  "target-unavailable": "対象のアカウントが見つからないか、凍結か非公開です",
  "rate-limited": "X が要求を制限しています",
  temporary: "通信に失敗しました",
  abnormal: "X の応答が想定と違いました",
  other: "取得に失敗しました",
};

export function failureText(kind: FetchFailureKind): string {
  return FAILURE_TEXT[kind];
}

const JST = new Intl.DateTimeFormat("ja-JP", {
  timeZone: "Asia/Tokyo",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  hourCycle: "h23",
});

/** 日本時間の「YYYY-MM-DD HH:MM」。 */
export function formatJst(date: Date): string {
  const parts: Record<string, string> = {};
  for (const p of JST.formatToParts(date)) parts[p.type] = p.value;
  return `${parts.year}-${parts.month}-${parts.day} ${parts.hour}:${parts.minute}`;
}

export const TRUNCATION_MARK = "…（長いため途中まで）";

/**
 * ポストの通。1 行目にアカウント名、2 行目に日本時間の日時、3 行目から本文、最後の行に URL。
 * 書き換えた後の長さ（measure）が上限（limit）を超えるときは、本文を切り詰めて印を付ける（D7）。
 */
export function postMessage(post: PostFacts, account: string, limit: number, measure: (text: string) => number): string {
  const head = `@${account}\n${formatJst(postedAtOf(post))}（日本時間）\n`;
  const build = (body: string) => `${head}${body}\n${post.url}`;
  const full = build(post.text);
  if (measure(full) <= limit) return full;
  const chars = Array.from(post.text);
  // 印を付けた形が上限に収まる、最も長い本文の先頭を探す。
  let lo = 0;
  let hi = chars.length;
  while (lo < hi) {
    const mid = Math.ceil((lo + hi) / 2);
    if (measure(build(chars.slice(0, mid).join("") + TRUNCATION_MARK)) <= limit) lo = mid;
    else hi = mid - 1;
  }
  return build(chars.slice(0, lo).join("") + TRUNCATION_MARK);
}

function names(accounts: readonly string[]): string {
  return accounts.map((a) => `@${a}`).join("、");
}

export function noNewPostsMessage(accounts: readonly string[]): string {
  return `新しいポストはありません（確かめたアカウント: ${names(accounts)}）`;
}

export type AccountFailure = { account: string; kind: FetchFailureKind };

/** 取得の失敗の通（1 回の実行で 1 通。アカウントごとに 1 行）。 */
export function fetchFailureMessage(failures: readonly AccountFailure[]): string {
  return ["X からの取得に失敗しました", ...failures.map((f) => `@${f.account}: ${failureText(f.kind)}`)].join("\n");
}

/** 取得の失敗の出力の 1 行。 */
export function fetchFailureLine(failures: readonly AccountFailure[]): string {
  return `X からの取得に失敗しました: ${failures.map((f) => `@${f.account}（${failureText(f.kind)}）`).join("、")}`;
}

export function maybeMissedMessage(accounts: readonly string[]): string {
  return `取得した件数より古いポストが通知されずに漏れたおそれがあります: ${names(accounts)}`;
}

export const RECORD_UNREADABLE = "通知済みの記録が読めないため、ポストを投稿しませんでした（記録はそのまま残しています）";
export const CONFIG_UNREADABLE = "対象のアカウントの設定が無いか読めないため、取得しませんでした";
export const LOCK_BUSY = "ほかの実行が動いているため、何もせずに終わります";
export const UNEXPECTED_FAILURE = "想定外の失敗で止まりました";
export const DEBUG_REMOVED = "環境変数 DEBUG を消してから動かしました";
export const NODE_DEBUG_SET = "環境変数 NODE_DEBUG が設定されているため止めました（送り先が出力に出るおそれがあるため、外してから実行してください）";
export const SECRETS_INSECURE = "秘匿値のファイルが所有者以外にも読める権限になっているため止めました（権限を 600 にしてください）";
export const SECRETS_FOREIGN_OWNER = "秘匿値のファイルの持ち主が、実行している利用者と違うため止めました（持ち主を確かめてください）";
export const SECRETS_UNREADABLE = "秘匿値のファイルを読めないため止めました（ファイルの権限を確かめてください）";
export const RECORD_WRITE_FAILED =
  "通知済みの記録に書き込めなかったため止めました（記録を直してから実行すると、同じポストが再び投稿されることがあります）";

export function countLine(count: number): string {
  return `通知した件数: ${count}`;
}

export function postFailedLine(count: number): string {
  return `Slack への投稿に失敗したため止めました（通知した件数: ${count}）`;
}

/** 秘匿値の問題の 1 行。 */
export function secretsFailureLine(
  failure: { reason: "missing"; missing: readonly string[]; malformed: readonly string[] } | { reason: "insecure" | "foreign-owner" | "unreadable" },
): string {
  if (failure.reason === "insecure") return SECRETS_INSECURE;
  if (failure.reason === "foreign-owner") return SECRETS_FOREIGN_OWNER;
  if (failure.reason !== "missing") return SECRETS_UNREADABLE;
  return secretsProblemLine(failure.missing, failure.malformed);
}

/** 秘匿値が足りないか形が違うときの 1 行（変数の名前だけを挙げ、値は出さない）。 */
export function secretsProblemLine(missing: readonly string[], malformed: readonly string[]): string {
  const parts: string[] = [];
  if (missing.length > 0) parts.push(`秘匿値が足りません: ${missing.join("、")}`);
  if (malformed.length > 0) parts.push(`秘匿値の形が違います: ${malformed.join("、")}`);
  return parts.join("。");
}
