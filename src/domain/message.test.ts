import { test } from "node:test";
import assert from "node:assert/strict";
import {
  fetchFailureLine,
  fetchFailureMessage,
  formatJst,
  INTERRUPTED,
  MACHINE_TRANSLATED_MARK,
  maybeMissedMessage,
  noNewPostsMessage,
  postMessage,
  secretsProblemLine,
  showTextLine,
  translationDurationLine,
  translationFailedLine,
  TRANSLATION_FAILED_MARK,
  TRUNCATION_MARK,
  TRY_NOT_TRANSLATED,
  TRY_TRANSLATED,
  TRY_TRANSLATION_FAILED,
  tryTranslateTooLongLine,
} from "./message.ts";
import type { PostFacts } from "./post.ts";

function post(text: string): PostFacts {
  return {
    id: "1590000000000000000",
    authorId: "100",
    authorName: "Example",
    isRetweet: false,
    isQuote: false,
    isReply: false,
    isPinned: false,
    postedAt: new Date("2026-11-09T01:30:00Z"),
    text,
    url: "https://x.com/Example/status/1590000000000000000",
  };
}

const plainLength = (s: string) => s.length;

test("日本時間の YYYY-MM-DD HH:MM で書く", () => {
  assert.equal(formatJst(new Date("2026-11-09T01:30:00Z")), "2026-11-09 10:30");
  assert.equal(formatJst(new Date("2026-12-31T15:05:00Z")), "2027-01-01 00:05");
});

test("XPOST-1: ポストの通は、アカウント名・日本時間の日時・本文の全文・URL の順", () => {
  const text = postMessage(post("一行目\n二行目"), { text: "一行目\n二行目" }, "AnthropicAI", 40000, plainLength);
  assert.equal(
    text,
    "@AnthropicAI\n2026-11-09 10:30（日本時間）\n一行目\n二行目\nhttps://x.com/Example/status/1590000000000000000",
  );
});

test("XPOST-19: 書き換えた後の長さが上限を超えるときは本文を切り詰め、印と URL を残す", () => {
  const escapeLength = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").length;
  const body = "<&>".repeat(100);
  const limit = 200;
  const text = postMessage(post(body), { text: body }, "AnthropicAI", limit, escapeLength);
  assert.ok(escapeLength(text) <= limit, `長さ ${escapeLength(text)}`);
  assert.ok(text.includes(TRUNCATION_MARK));
  assert.ok(text.startsWith("@AnthropicAI\n"));
  assert.ok(text.endsWith("\nhttps://x.com/Example/status/1590000000000000000"));
  // 切り詰めは上限に収まる最も長い形（1 文字足すと超える）
  const shown = text.split("\n")[2] ?? "";
  const kept = shown.slice(0, shown.length - TRUNCATION_MARK.length);
  assert.equal(kept, body.slice(0, kept.length));
  const longer = text.replace(kept + TRUNCATION_MARK, body.slice(0, kept.length + 1) + TRUNCATION_MARK);
  assert.ok(escapeLength(longer) > limit);
});

test("XPJA-1 / D8: 印は本文の次の行に置き、その次の行に URL を置く", () => {
  const text = postMessage(post("We're releasing a new model today."), { text: "本日、新しいモデルを公開します。", mark: MACHINE_TRANSLATED_MARK }, "AnthropicAI", 40000, plainLength);
  assert.equal(
    text,
    "@AnthropicAI\n2026-11-09 10:30（日本時間）\n本日、新しいモデルを公開します。\n（機械翻訳）\nhttps://x.com/Example/status/1590000000000000000",
  );
  assert.ok(!text.includes("We're releasing"));
});

test("XPJA-3: 失敗の印は原文の次の行に付き、機械翻訳の印は付かない", () => {
  const original = "We're releasing a new model today.";
  const text = postMessage(post(original), { text: original, mark: TRANSLATION_FAILED_MARK }, "AnthropicAI", 40000, plainLength);
  assert.equal(
    text,
    `@AnthropicAI\n2026-11-09 10:30（日本時間）\n${original}\n（翻訳に失敗したため原文のまま）\nhttps://x.com/Example/status/1590000000000000000`,
  );
  assert.ok(!text.includes(MACHINE_TRANSLATED_MARK));
});

test("XPJA-4 / XPJA-9: 印が無い本文は、これまでと同じ形", () => {
  const text = postMessage(post("Claude Opus 5"), { text: "Claude Opus 5" }, "AnthropicAI", 40000, plainLength);
  assert.equal(text, "@AnthropicAI\n2026-11-09 10:30（日本時間）\nClaude Opus 5\nhttps://x.com/Example/status/1590000000000000000");
});

for (const mark of [MACHINE_TRANSLATED_MARK, TRANSLATION_FAILED_MARK] as const) {
  test(`XPJA-5: 上限を超えるときは本文だけを切り詰め、${mark} と URL を残す`, () => {
    const body = "長い訳文の一文です。".repeat(50);
    const limit = 150;
    const text = postMessage(post("long"), { text: body, mark }, "AnthropicAI", limit, plainLength);
    assert.ok(text.length <= limit, `長さ ${text.length}`);
    const lines = text.split("\n");
    assert.equal(lines.length, 5);
    assert.ok(lines[2]?.endsWith(TRUNCATION_MARK));
    assert.equal(lines[3], mark);
    assert.equal(lines[4], "https://x.com/Example/status/1590000000000000000");
    // 切り詰めは上限に収まる最も長い形（1 文字足すと超える）
    const kept = (lines[2] ?? "").slice(0, -TRUNCATION_MARK.length);
    assert.equal(kept, body.slice(0, kept.length));
    const longer = text.replace(kept + TRUNCATION_MARK, body.slice(0, kept.length + 1) + TRUNCATION_MARK);
    assert.ok(longer.length > limit);
  });
}

test("XPJA-3: 翻訳の失敗の行は 1 行で件数を含む", () => {
  assert.equal(translationFailedLine(2), "翻訳に失敗したため原文のまま投稿したポストの件数: 2");
  assert.ok(!translationFailedLine(2).includes("\n"));
});

test("D18: --try-translate の固定の文面と、終了要求の行", () => {
  assert.deepEqual([TRY_TRANSLATED, TRY_NOT_TRANSLATED, TRY_TRANSLATION_FAILED], ["訳した", "訳さなかった", "翻訳に失敗した"]);
  assert.equal(translationDurationLine(6.34), "所要時間: 6.3 秒");
  assert.equal(tryTranslateTooLongLine(100000), "本文が長すぎるため訳しませんでした（100000 文字まで）");
  assert.equal(INTERRUPTED, "中断の要求を受けたため止めました");
});

test("D17: --show-text の本文の行は、本文の改行を含んでも 1 行", () => {
  assert.equal(showTextLine("一行目\n\"二行目\""), '本文="一行目\\n\\"二行目\\""');
});

test("XPOST-3 / XPOST-17: 新しいポストが無い旨は、確かめたアカウントを並べた 1 文", () => {
  assert.equal(noNewPostsMessage(["AnthropicAI"]), "新しいポストはありません（確かめたアカウント: @AnthropicAI）");
  assert.equal(noNewPostsMessage(["AnthropicAI", "Q"]), "新しいポストはありません（確かめたアカウント: @AnthropicAI、@Q）");
});

test("XPOST-23 / D10: 取得の失敗は 1 通にまとめ、アカウントごとに種類の文を並べる", () => {
  const failures = [
    { account: "AnthropicAI", kind: "login-rejected" as const },
    { account: "Q", kind: "target-unavailable" as const },
  ];
  assert.equal(
    fetchFailureMessage(failures),
    "X からの取得に失敗しました\n@AnthropicAI: 取得用のアカウントのログインが拒まれました\n@Q: 対象のアカウントが見つからないか、凍結か非公開です",
  );
  assert.ok(!fetchFailureLine(failures).includes("\n"));
  assert.ok(fetchFailureLine(failures).includes("@Q"));
});

test("XPOST-20: 漏れのおそれの通にアカウント名が入る", () => {
  assert.ok(maybeMissedMessage(["AnthropicAI"]).includes("@AnthropicAI"));
});

test("XPOST-9: 秘匿値の 1 行は変数の名前だけを挙げる", () => {
  assert.equal(secretsProblemLine(["X_CT0"], []), "秘匿値が足りません: X_CT0");
  assert.equal(
    secretsProblemLine(["X_CT0"], ["SLACK_WEBHOOK_URL"]),
    "秘匿値が足りません: X_CT0。秘匿値の形が違います: SLACK_WEBHOOK_URL",
  );
});
