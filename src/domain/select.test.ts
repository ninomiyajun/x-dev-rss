import { test } from "node:test";
import assert from "node:assert/strict";
import { classifyAll } from "./post.ts";
import type { PostFacts } from "./post.ts";
import { CANDIDATE_LIMIT, countsTowardLimit, selectForAccount, TimelineCollector } from "./select.ts";

const ME = "100";

function own(id: number, extra: Partial<PostFacts> = {}): PostFacts {
  return {
    id: String(id),
    authorId: ME,
    authorName: "Example",
    isRetweet: false,
    isQuote: false,
    isReply: false,
    isPinned: false,
    postedAt: undefined,
    text: `本文 ${id}`,
    url: `https://x.com/Example/status/${id}`,
    ...extra,
  };
}
const retweet = (id: number) => own(id, { isRetweet: true });
const reply = (id: number) => own(id, { isReply: true });

function ids(posts: readonly PostFacts[]): string[] {
  return posts.map((p) => p.id);
}

test("「20 件」の数え方は区画の定数と関数にまとまっている（通常のポストだけで数える）", () => {
  assert.equal(CANDIDATE_LIMIT, 20);
  assert.equal(countsTowardLimit("own"), true);
  assert.equal(countsTowardLimit("retweet"), false);
  assert.equal(countsTowardLimit("reply"), false);
  assert.equal(countsTowardLimit("quote"), false);
});

test("XPOST-1: 記録に無い候補を古い順に返す", () => {
  const posts = classifyAll([own(30), own(10), own(20)], ME);
  const s = selectForAccount(posts, new Set(["10"]), "exhausted");
  assert.deepEqual(ids(s.toPost), ["20", "30"]);
  assert.deepEqual(s.toRecordWithoutPosting, []);
  assert.equal(s.maybeMissed, false);
});

test("XPOST-4: 初めての実行では最も新しい 1 件だけを投稿し、残りを記録する", () => {
  const list: PostFacts[] = [];
  for (let i = 1; i <= 20; i++) list.push(own(i));
  list.push(retweet(25));
  const s = selectForAccount(classifyAll(list, ME), undefined, "enough");
  assert.deepEqual(ids(s.toPost), ["20"]);
  assert.equal(s.toRecordWithoutPosting.length, 20);
  assert.ok(!s.toRecordWithoutPosting.includes("20"));
  assert.ok(s.toRecordWithoutPosting.includes("25"));
  assert.equal(s.maybeMissed, false);
});

test("XPOST-4: 初めての実行で数える対象が 20 件に満たないときも、同じ規則で 1 件だけ投稿する", () => {
  const s = selectForAccount(classifyAll([own(1), own(2), retweet(3)], ME), undefined, "exhausted");
  assert.deepEqual(ids(s.toPost), ["2"]);
  assert.deepEqual(s.toRecordWithoutPosting.sort(), ["1", "3"]);
  const empty = selectForAccount([], undefined, "exhausted");
  assert.deepEqual([empty.toPost, empty.toRecordWithoutPosting], [[], []]);
});

test("XPOST-5: 候補は数える対象の新しいほうから 20 件だけで、返信・リポスト・引用は数えない", () => {
  const list: PostFacts[] = [];
  for (let i = 1; i <= 25; i++) {
    list.push(own(i * 10));
    if (i % 5 === 0) list.push(retweet(i * 10 + 1), reply(i * 10 + 2));
  }
  // 記録にあるのは 25 件のうち 1 件（最も新しいもの）
  const s = selectForAccount(classifyAll(list, ME), new Set(["250"]), "enough");
  assert.equal(s.toPost.length, 19);
  assert.equal(s.toPost[0]?.id, "60"); // 21 位より古い 10〜50 の 5 件は投稿しない
  assert.ok(!ids(s.toPost).includes("50"));
  // 記録する範囲は 20 位（60）以上の ID の返信とリポストだけ
  assert.deepEqual(s.toRecordWithoutPosting.sort(), ["101", "102", "151", "152", "201", "202", "251", "252"].sort());
});

test("XPOST-6: 通常のポストだけを投稿し、引用・返信・リポストは投稿せずに記録する", () => {
  const list = [own(1), retweet(2), own(3, { isQuote: true }), reply(4), reply(5)];
  const s = selectForAccount(classifyAll(list, ME), new Set(["0"]), "exhausted");
  assert.deepEqual(ids(s.toPost), ["1"]);
  assert.deepEqual(s.toRecordWithoutPosting.sort(), ["2", "3", "4", "5"]);
});

function pinnedCase(rank: "1" | "20" | "21" | "oldest") {
  // 固定表示でないポストは 10010〜10250 の 25 件（10 刻み）。固定表示のポスト P の ID を、順位に合わせて決める。
  const list: PostFacts[] = [];
  for (let i = 1; i <= 25; i++) list.push(own(10000 + i * 10));
  const pid = { "1": 20000, "20": 10065, "21": 10055, oldest: 10 }[rank];
  const p = own(pid, { isPinned: true });
  return { posts: [p, ...list], pid: p.id };
}

test("XPOST-16: 固定表示のポストは 20 位以内のときだけ候補になり、20 位のときは 20 番目が外れる", () => {
  for (const rank of ["1", "20", "21", "oldest"] as const) {
    const { posts, pid } = pinnedCase(rank);
    // 記録には、最も新しい固定表示でないポストより古い 1 件がある（初めての実行ではない）
    const recorded = new Set(["10010"]);
    const s = selectForAccount(classifyAll(posts, ME), recorded, "enough");
    const posted = ids(s.toPost);
    if (rank === "1" || rank === "20") {
      assert.ok(posted.includes(pid), `rank ${rank}`);
      assert.equal(s.ranks.get(pid), Number(rank));
    } else {
      assert.ok(!posted.includes(pid), `rank ${rank}`);
    }
    if (rank === "20") assert.ok(!posted.includes("10060"), "固定表示でない 20 番目は候補から外れる");
    // 2 回目: 1 回目に投稿したものを記録に足すと、P は投稿されない
    const second = selectForAccount(classifyAll(posts, ME), new Set([...recorded, ...posted]), "enough");
    assert.ok(!ids(second.toPost).includes(pid));
  }
});


function twenty(extra: PostFacts[] = []) {
  const list: PostFacts[] = [];
  for (let i = 1; i <= 22; i++) list.push(own(100 + i)); // 新しいほうから 20 件は 103〜122
  return classifyAll([...list, ...extra], ME);
}

test("XPOST-20: 20 件そろって止め、新しいほうから 20 件が記録に 1 件も無ければ漏れのおそれ", () => {
  assert.equal(selectForAccount(twenty(), new Set(["1"]), "enough").maybeMissed, true);
  // (1) 並びの終わりまで取得したときは知らせない
  assert.equal(selectForAccount(twenty(), new Set(["1"]), "exhausted").maybeMissed, false);
  // (3) 記録の項目はあるが ID が空 → 知らせる
  assert.equal(selectForAccount(twenty(), new Set(), "enough").maybeMissed, true);
  // 初めての実行（項目が無い）では知らせない
  assert.equal(selectForAccount(twenty(), undefined, "enough").maybeMissed, false);
});

test("XPOST-20 (2): 記録済みの返信・リポスト・引用は判定に数えない", () => {
  const posts = twenty([reply(130), retweet(131), own(132, { isQuote: true })]);
  assert.equal(selectForAccount(posts, new Set(["130", "131", "132"]), "enough").maybeMissed, true);
});

test("XPOST-20 (4): 記録と重なるのが 21 位以下の通常のポストだけなら知らせる", () => {
  const s = selectForAccount(twenty(), new Set(["101", "102"]), "enough");
  assert.equal(s.maybeMissed, true);
  assert.ok(!ids(s.toPost).includes("101"));
  assert.equal(s.toPost.length, 20);
});

test("XPOST-20 (5): 20 件の中の固定表示のポストが記録にあれば知らせない", () => {
  const posts = twenty([own(200, { isPinned: true })]);
  assert.equal(selectForAccount(posts, new Set(["200"]), "enough").maybeMissed, false);
});

test("XPOST-20 (6): 上限で止まり 20 件そろわなくても、見つかった通常のポストが記録に 1 件も無いときだけ知らせる", () => {
  const posts = classifyAll([own(10), own(11), retweet(12)], ME);
  const none = selectForAccount(posts, new Set(["12"]), "limit");
  assert.equal(none.maybeMissed, true);
  assert.deepEqual(ids(none.toPost), ["10", "11"]);
  // 見つかった通常のポストに記録済みのものがあれば知らせない
  const s = selectForAccount(posts, new Set(["10"]), "limit");
  assert.equal(s.maybeMissed, false);
  assert.deepEqual(ids(s.toPost), ["11"]);
  // 固定表示のポストも数える
  const pinned = classifyAll([own(5, { isPinned: true }), own(11)], ME);
  assert.equal(selectForAccount(pinned, new Set(["5"]), "limit").maybeMissed, false);
  // 上限で止まっても 20 件そろっていれば、20 件の重なりで決める
  assert.equal(selectForAccount(twenty(), new Set(["122"]), "limit").maybeMissed, false);
});

test("集め役: 固定表示でない通常のポストが 20 件そろうと enough になり、重複を除き、順不同でも 20 位以内が欠けない", () => {
  const c = new TimelineCollector(ME);
  const ids25 = Array.from({ length: 25 }, (_, i) => 1000 + i);
  // 順不同（ID の順でない）に並べる
  const shuffled = [...ids25].sort((a, b) => ((a * 7919) % 25) - ((b * 7919) % 25));
  c.add(own(5000, { isPinned: true }));
  c.add(retweet(4000));
  for (const id of shuffled.slice(0, 19)) c.add(own(id));
  assert.equal(c.enough, false);
  c.add(own(shuffled[0] ?? 0)); // 重複は数えない
  assert.equal(c.enough, false);
  for (const id of shuffled.slice(19)) c.add(own(id)); // ページを読み切る
  assert.equal(c.enough, true);
  const s = selectForAccount(classifyAll(c.collected(), ME), new Set(["1"]), "enough");
  // 固定表示（5000）が 1 位、続いて 1024〜1006 の 19 件
  const expected = ["5000", ...Array.from({ length: 19 }, (_, i) => String(1024 - i))];
  assert.deepEqual([...s.ranks].filter(([, r]) => r <= 20).map(([id]) => id).sort(), expected.sort());
});
