// 試し取得（--dry-run）の本文の行（--show-text。計画の D17）の試験。取得は偽物に差し替える。
import { test } from "node:test";
import assert from "node:assert/strict";
import { inspect } from "./inspect.ts";
import { fakePost, fetched, harness } from "./fakes.ts";

const TEXT = 'Run `claude --help` with @claudeai\nand read "https://www.anthropic.com/news" #AI';

test("D17: --show-text が無ければ本文の行を出さない（既定の出力は変わらない）", async () => {
  const h = harness({ fetch: { AnthropicAI: fetched([fakePost(2, { text: TEXT }), fakePost(1)]) } });
  assert.equal(await inspect(h.deps), 0);
  assert.equal(h.lines.length, 5);
  assert.ok(!h.lines.some((l) => l.startsWith("本文=")));
  assert.deepEqual(h.translator.calls, []);
});

test("D17: --show-text のときは、各ポストの行の次に、本文を JSON の文字列の形にした 1 行を出す。翻訳も投稿も記録もしない", async () => {
  const h = harness({ fetch: { AnthropicAI: fetched([fakePost(2, { text: TEXT }), fakePost(1)]) } });
  assert.equal(await inspect({ ...h.deps, showText: true }), 0);
  assert.equal(h.lines[0], "@AnthropicAI");
  assert.match(h.lines[1] ?? "", /^2 .* 種類=通常/);
  assert.equal(h.lines[2], `本文=${JSON.stringify(TEXT)}`);
  // 本文の改行で行が分かれない
  assert.ok(!(h.lines[2] ?? "").includes("\n"));
  assert.match(h.lines[3] ?? "", /^1 .* 種類=通常/);
  assert.equal(h.lines[4], '本文="本文 1"');
  assert.deepEqual(h.lines.slice(5), ["取得: 並びの終わりまで取得した", "X への要求の回数: 2"]);
  assert.deepEqual(h.translator.calls, []);
  assert.deepEqual(h.poster.attempts, []);
  assert.deepEqual(h.record.writes, []);
});
