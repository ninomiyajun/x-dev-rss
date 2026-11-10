// 訳す流れ（bodyFor）と、訳だけを試す流れ（tryTranslate）の試験（計画の手順 6）。翻訳・待ち・時刻は偽物に差し替える。
import { test } from "node:test";
import assert from "node:assert/strict";
import { bodyFor, newTranslationState, TRANSLATE_RETRY_DELAY_MS, tryTranslate } from "./translate.ts";
import type { TryTranslateDeps } from "./translate.ts";
import { FakeTime, FakeTranslator } from "./fakes.ts";
import { MACHINE_TRANSLATED_MARK, TRANSLATION_FAILED_MARK } from "../domain/message.ts";

const EN = "We're releasing a new model today.";
const JA = "本日、新しいモデルを公開します。";

function deps(): { deps: TryTranslateDeps; translator: FakeTranslator; time: FakeTime; lines: string[] } {
  const translator = new FakeTranslator();
  const time = new FakeTime();
  const lines: string[] = [];
  return { deps: { translator, sleep: time.sleep, now: time.now, out: (l) => lines.push(l) }, translator, time, lines };
}

test("bodyFor: 訳さないポストは翻訳を呼ばず、原文のまま印なし", async () => {
  const d = deps();
  assert.deepEqual(await bodyFor(JA, d.deps, newTranslationState()), { body: { text: JA }, failed: false });
  assert.deepEqual(d.translator.calls, []);
});

test("bodyFor: 1 回目で検証を通れば、前後の空白を除いた訳文に機械翻訳の印。待たない", async () => {
  const d = deps();
  d.translator.set(EN, { ok: true, text: ` ${JA}\n` });
  assert.deepEqual(await bodyFor(EN, d.deps, newTranslationState()), { body: { text: JA, mark: MACHINE_TRANSLATED_MARK }, failed: false });
  assert.deepEqual(d.translator.calls, [{ text: EN, attempt: 1 }]);
  assert.deepEqual(d.time.sleeps, []);
});

test("bodyFor: 1 回目が失敗なら 5 秒待って attempt 2 で試し、通れば訳文", async () => {
  const d = deps();
  d.translator.set(EN, { ok: false, reason: "timeout" }, { ok: true, text: JA });
  const state = newTranslationState();
  assert.deepEqual(await bodyFor(EN, d.deps, state), { body: { text: JA, mark: MACHINE_TRANSLATED_MARK }, failed: false });
  assert.deepEqual(
    d.translator.calls.map((c) => c.attempt),
    [1, 2],
  );
  assert.deepEqual(d.time.sleeps, [TRANSLATE_RETRY_DELAY_MS]);
  assert.equal(TRANSLATE_RETRY_DELAY_MS, 5000);
  assert.equal(state.stopped, false);
});

test("bodyFor: 2 回とも外との接続の失敗なら原文に失敗の印で、この実行の翻訳を止める。止めた後は呼ばない", async () => {
  const d = deps();
  d.translator.set(EN, { ok: false, reason: "failed" }, { ok: false, reason: "timeout" });
  const state = newTranslationState();
  assert.deepEqual(await bodyFor(EN, d.deps, state), { body: { text: EN, mark: TRANSLATION_FAILED_MARK }, failed: true });
  assert.equal(state.stopped, true);
  const other = "Another English post for today.";
  assert.deepEqual(await bodyFor(other, d.deps, state), { body: { text: other, mark: TRANSLATION_FAILED_MARK }, failed: true });
  assert.equal(d.translator.calls.length, 2);
  // 止めた後も、訳さないポストは原文のまま印なし
  assert.deepEqual(await bodyFor(JA, d.deps, state), { body: { text: JA }, failed: false });
});

test("bodyFor（D21）: 1 回目が unavailable なら、2 回目を試さず待たずに原文に失敗の印で、この実行の翻訳を止める", async () => {
  const d = deps();
  d.translator.set(EN, { ok: false, reason: "unavailable" }, { ok: true, text: JA });
  const state = newTranslationState();
  assert.deepEqual(await bodyFor(EN, d.deps, state), { body: { text: EN, mark: TRANSLATION_FAILED_MARK }, failed: true });
  assert.deepEqual(d.translator.calls, [{ text: EN, attempt: 1 }]);
  assert.deepEqual(d.time.sleeps, []);
  assert.equal(state.stopped, true);
  const other = "Another English post for today.";
  assert.deepEqual(await bodyFor(other, d.deps, state), { body: { text: other, mark: TRANSLATION_FAILED_MARK }, failed: true });
  assert.equal(d.translator.calls.length, 1);
});

test("bodyFor: 2 回目が unavailable でも、1 回目が timeout か failed なら 2 回とも試して止める", async () => {
  for (const reason of ["timeout", "failed"] as const) {
    const d = deps();
    d.translator.set(EN, { ok: false, reason }, { ok: false, reason: "unavailable" });
    const state = newTranslationState();
    assert.deepEqual(await bodyFor(EN, d.deps, state), { body: { text: EN, mark: TRANSLATION_FAILED_MARK }, failed: true });
    assert.equal(d.translator.calls.length, 2);
    assert.deepEqual(d.time.sleeps, [TRANSLATE_RETRY_DELAY_MS]);
    assert.equal(state.stopped, true);
  }
});

test("tryTranslate（D21）: 1 回目が unavailable なら、待たずに 翻訳に失敗した → 原文 → 失敗の印", async () => {
  const d = deps();
  d.translator.set(EN, { ok: false, reason: "unavailable" });
  assert.equal(await tryTranslate(EN, d.deps), 0);
  assert.deepEqual(d.lines, ["翻訳に失敗した", EN, "（翻訳に失敗したため原文のまま）", "所要時間: 0.0 秒"]);
});

test("bodyFor: 検証を通らなかっただけのときは失敗の印を付けるが、翻訳は止めない", async () => {
  const d = deps();
  // 原文の丸写し（5 語以上）は検証を通らない
  d.translator.set(EN, { ok: true, text: EN });
  const state = newTranslationState();
  assert.deepEqual(await bodyFor(EN, d.deps, state), { body: { text: EN, mark: TRANSLATION_FAILED_MARK }, failed: true });
  assert.equal(state.stopped, false);
  // 1 回は接続の失敗、1 回は検証の失敗でも止めない
  d.translator.set(EN, { ok: false, reason: "failed" }, { ok: true, text: EN });
  await bodyFor(EN, d.deps, state);
  assert.equal(state.stopped, false);
});

test("bodyFor: 口が例外を投げても外へ出さず、接続の失敗として扱う", async () => {
  const d = deps();
  d.translator.set(EN, "throw");
  const state = newTranslationState();
  assert.deepEqual(await bodyFor(EN, d.deps, state), { body: { text: EN, mark: TRANSLATION_FAILED_MARK }, failed: true });
  assert.equal(state.stopped, true);
});

test("bodyFor（XPJA-9 / D15）: 4 語以下で原文と同じ文字が返れば、1 回目で印なしの原文。2 回目は試さない", async () => {
  const d = deps();
  d.translator.set("Claude Opus 5", { ok: true, text: " Claude Opus 5 " });
  assert.deepEqual(await bodyFor("Claude Opus 5", d.deps, newTranslationState()), { body: { text: "Claude Opus 5" }, failed: false });
  assert.equal(d.translator.calls.length, 1);
  assert.deepEqual(d.time.sleeps, []);
});

test("bodyFor（XPJA-10）: 5 語以上で原文と同じ文字が 2 回返れば失敗の印", async () => {
  const d = deps();
  const text = "Meet the new Claude model";
  d.translator.set(text, { ok: true, text });
  assert.deepEqual(await bodyFor(text, d.deps, newTranslationState()), { body: { text, mark: TRANSLATION_FAILED_MARK }, failed: true });
  assert.equal(d.translator.calls.length, 2);
});

test("tryTranslate（D18）: 訳した → 本文 → 機械翻訳の印 → 所要時間の行。終了コード 0", async () => {
  const d = deps();
  d.translator.set(EN, { ok: false, reason: "failed" }, { ok: true, text: JA });
  assert.equal(await tryTranslate(EN, d.deps), 0);
  // 5 秒の待ちが所要時間に入る
  assert.deepEqual(d.lines, ["訳した", JA, "（機械翻訳）", "所要時間: 5.0 秒"]);
});

test("tryTranslate: 訳さなかった（日本語のポストと、訳す必要の無いポスト）は、原文と同じ本文で印なし", async () => {
  const d = deps();
  assert.equal(await tryTranslate(JA, d.deps), 0);
  assert.deepEqual(d.lines, ["訳さなかった", JA, "所要時間: 0.0 秒"]);
  d.lines.length = 0;
  d.translator.set("Claude Opus 5", { ok: true, text: "Claude Opus 5" });
  await tryTranslate("Claude Opus 5", d.deps);
  assert.deepEqual(d.lines, ["訳さなかった", "Claude Opus 5", "所要時間: 0.0 秒"]);
});

test("tryTranslate: 翻訳に失敗した → 原文 → 失敗の印 → 所要時間の行。終了コード 0", async () => {
  const d = deps();
  d.translator.set(EN, { ok: false, reason: "timeout" });
  assert.equal(await tryTranslate(EN, d.deps), 0);
  assert.deepEqual(d.lines, ["翻訳に失敗した", EN, "（翻訳に失敗したため原文のまま）", "所要時間: 5.0 秒"]);
});
