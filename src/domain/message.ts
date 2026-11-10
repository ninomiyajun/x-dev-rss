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

/** 機械翻訳の印（仕様 XPJA の語の定義）。翻訳の手段で訳した本文にだけ付ける。 */
export const MACHINE_TRANSLATED_MARK = "（機械翻訳）";
/** 翻訳の失敗の印（仕様 XPJA の語の定義）。訳そうとして訳せなかった本文にだけ付ける。 */
export const TRANSLATION_FAILED_MARK = "（翻訳に失敗したため原文のまま）";

export type TranslationMark = typeof MACHINE_TRANSLATED_MARK | typeof TRANSLATION_FAILED_MARK;

/** 通に載せる本文と、その後の行に付ける印（印が無いこともある）。 */
export type PostBody = { text: string; mark?: TranslationMark };

/**
 * ポストの通。1 行目にアカウント名、2 行目に日本時間の日時、3 行目から本文、印があれば本文の次の行に印、最後の行に URL（計画の D8）。
 * 書き換えた後の長さ（measure）が上限（limit）を超えるときは、本文だけを切り詰めて切り詰めの印を付け、印と URL は残す（D7・XPJA-5）。
 */
export function postMessage(post: PostFacts, body: PostBody, account: string, limit: number, measure: (text: string) => number): string {
  const head = `@${account}\n${formatJst(postedAtOf(post))}（日本時間）\n`;
  const tail = body.mark === undefined ? `\n${post.url}` : `\n${body.mark}\n${post.url}`;
  const build = (text: string) => `${head}${text}${tail}`;
  const full = build(body.text);
  if (measure(full) <= limit) return full;
  const chars = Array.from(body.text);
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

/** 翻訳の失敗の出力の 1 行（1 回の実行で 1 行。XPJA-3）。 */
export function translationFailedLine(count: number): string {
  return `翻訳に失敗したため原文のまま投稿したポストの件数: ${count}`;
}

// ---- 訳だけを試す流れ（--try-translate）の固定の文面（D18）。行の順は実行の流れが決める ----

/** 1 行目: 訳した（判定が英語のポストとし、訳文が検証を通った）。 */
export const TRY_TRANSLATED = "訳した";
/** 1 行目: 訳さなかった（日本語のポストか、訳す文の無いポストか、訳す必要の無いポスト）。 */
export const TRY_NOT_TRANSLATED = "訳さなかった";
/** 1 行目: 翻訳に失敗した（原文のまま）。 */
export const TRY_TRANSLATION_FAILED = "翻訳に失敗した";

/** 所要時間の行。 */
export function translationDurationLine(seconds: number): string {
  return `所要時間: ${seconds.toFixed(1)} 秒`;
}

/** 標準入力の本文が長すぎるときの行。 */
export function tryTranslateTooLongLine(limit: number): string {
  return `本文が長すぎるため訳しませんでした（${limit} 文字まで）`;
}

/** 終了要求で止めたときの 1 行（D14）。 */
export const INTERRUPTED = "中断の要求を受けたため止めました";

/** 試し取得の --show-text の本文の行（本文の改行で行が分かれないよう、JSON の文字列の形で書く。D17）。 */
export function showTextLine(text: string): string {
  return `本文=${JSON.stringify(text)}`;
}
