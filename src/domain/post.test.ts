import { test } from "node:test";
import assert from "node:assert/strict";
import { classifyAll, classifyPost, compareIds, dateFromId, isNotifiedKind, isRecordOnlyKind, postedAtOf } from "./post.ts";
import type { PostFacts } from "./post.ts";

const ME = "100";
const OTHER = "200";

function facts(id: string, extra: Partial<PostFacts> = {}): PostFacts {
  return {
    id,
    authorId: ME,
    authorName: "Example",
    isRetweet: false,
    isQuote: false,
    isReply: false,
    isPinned: false,
    postedAt: undefined,
    text: "本文",
    url: `https://x.com/Example/status/${id}`,
    ...extra,
  };
}

test("XPOST-6（利用者の判断で改めた規則）: 通常のポストだけを通知し、引用・返信・リポストは通知せずに記録する", () => {
  const kinds = classifyAll(
    [
      facts("1"),
      facts("2", { isQuote: true }),
      facts("3", { isRetweet: true }),
      facts("4", { isReply: true }), // ほかのアカウントへの返信
      facts("5", { isReply: true }), // 自分のポストへの返信（続きのポスト）も同じ扱い
    ],
    ME,
  ).map((c) => c.kind);
  assert.deepEqual(kinds, ["own", "quote", "retweet", "reply", "reply"]);
  assert.deepEqual(kinds.map(isNotifiedKind), [true, false, false, false, false]);
  assert.deepEqual(kinds.map(isRecordOnlyKind), [false, true, true, true, true]);
});

test("D11: 重なったときは投稿しない側を優先し、他人のポストは数えも記録もしない", () => {
  assert.equal(classifyPost(facts("1", { isRetweet: true, isQuote: true }), ME).kind, "retweet");
  assert.equal(classifyPost(facts("2", { isQuote: true, isReply: true }), ME).kind, "reply");
  assert.equal(classifyPost(facts("3", { authorId: OTHER }), ME).kind, "foreign");
  assert.equal(isRecordOnlyKind("foreign"), false);
  assert.equal(isNotifiedKind("foreign"), false);
});

test("D14: ID は BigInt で比べ、日時が無ければ ID から求める", () => {
  assert.ok(compareIds("10000000000000000000", "9999999999999999999") > 0);
  assert.equal(compareIds("5", "5"), 0);
  const d = dateFromId("1590000000000000000");
  assert.equal(d.getTime(), Number((1590000000000000000n >> 22n) + 1288834974657n));
  const given = new Date("2026-11-09T01:30:00Z");
  assert.equal(postedAtOf(facts("1590000000000000000", { postedAt: given })), given);
  assert.equal(postedAtOf(facts("1590000000000000000")).getTime(), d.getTime());
});
