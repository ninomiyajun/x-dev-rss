// ポストの中立な事実と、種類の判定（計画の D6・D11・D14）。入出力を持たない。

/** 取得の手段によらない、1 件のポストの事実。ID は 10 進数の文字列。 */
export type PostFacts = {
  id: string;
  authorId: string | undefined;
  authorName: string | undefined;
  isRetweet: boolean;
  isQuote: boolean;
  isReply: boolean;
  isPinned: boolean;
  postedAt: Date | undefined;
  text: string;
  url: string;
};

/**
 * ポストの種類。
 * - own: アカウント自身の通常のポスト（返信・リポスト・引用のどれでもないもの）
 * - quote: 引用（返信でないもの）
 * - reply: 返信（相手が自分でも他人でも同じ。D6）
 * - retweet: リポスト
 * - foreign: 投稿者が対象のアカウントでないポスト（会話のまとまりに入る他人のポスト。D11）
 */
export type PostKind = "own" | "quote" | "reply" | "retweet" | "foreign";

export type ClassifiedPost = {
  facts: PostFacts;
  kind: PostKind;
};

// ---- 通知する種類の規則（D6）。答えが変わったときに直すのは、この区画だけである ----
// 利用者の決定（2026-11-09）: 通知するのは通常のポストだけ。返信（相手を問わない）・リポスト・引用は通知しない。

/** 通知する（Slack へ投稿する）種類か。 */
export function isNotifiedKind(kind: PostKind): boolean {
  return kind === "own";
}
// ---- 通知する種類の規則の区画ここまで ----

/** 投稿しないが記録する種類か（記録する範囲の中で、種類で外すもの）。 */
export function isRecordOnlyKind(kind: PostKind): boolean {
  return kind !== "foreign" && !isNotifiedKind(kind);
}

/** 1 件のポストの種類を決める。重なったときは、投稿しない側を優先する（D11）。 */
export function classifyPost(facts: PostFacts, targetUserId: string): ClassifiedPost {
  if (facts.isRetweet) return { facts, kind: "retweet" };
  if (facts.authorId !== targetUserId) return { facts, kind: "foreign" };
  if (facts.isReply) return { facts, kind: "reply" };
  return { facts, kind: facts.isQuote ? "quote" : "own" };
}

/** 受け取ったポストを、すべて分類する。 */
export function classifyAll(posts: readonly PostFacts[], targetUserId: string): ClassifiedPost[] {
  return posts.map((p) => classifyPost(p, targetUserId));
}

// ---- D14: ID と日時 ----

const DECIMAL_ID = /^[0-9]+$/;

export function isDecimalId(id: string): boolean {
  return DECIMAL_ID.test(id);
}

/** ID の大きさで比べる（a が大きければ正）。 */
export function compareIds(a: string, b: string): number {
  const x = BigInt(a);
  const y = BigInt(b);
  return x === y ? 0 : x > y ? 1 : -1;
}

const X_EPOCH_MS = 1288834974657n;

/** X の ID の上位の桁が表す時刻。 */
export function dateFromId(id: string): Date {
  return new Date(Number((BigInt(id) >> 22n) + X_EPOCH_MS));
}

/** ポストの日時。無ければ ID から求める。 */
export function postedAtOf(facts: PostFacts): Date {
  return facts.postedAt ?? dateFromId(facts.id);
}
