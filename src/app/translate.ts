// ポストの本文を訳す流れと、訳だけを試す流れ（--try-translate）（計画の手順 6・D1・D5・D15・D18）。
// 判定と検証は判定と文面、訳は翻訳の口を通す。
import {
  MACHINE_TRANSLATED_MARK,
  TRANSLATION_FAILED_MARK,
  translationDurationLine,
  TRY_NOT_TRANSLATED,
  TRY_TRANSLATED,
  TRY_TRANSLATION_FAILED,
} from "../domain/message.ts";
import type { PostBody } from "../domain/message.ts";
import { acceptTranslation, isUntranslatedEcho, needsTranslation } from "../domain/translation.ts";
import type { Clock, Output, Sleep, TranslatePort, TranslateResult } from "./ports.ts";

/** 1 回目が駄目だったときの、2 回目の前の待ち（D5）。取得と投稿のやり直しの待ち（retry.ts）とは別に持つ（D21）。 */
export const TRANSLATE_RETRY_DELAY_MS = 5_000;

/** 訳す流れが使う口（InspectDeps と同じ考えの狭い型。D18）。 */
export type TryTranslateDeps = { translator: TranslatePort; sleep: Sleep; now: Clock; out: Output };

/** 1 回の実行の中で持ち越す状態。stopped が true なら、この実行では翻訳を止めた（D5）。 */
export type TranslationState = { stopped: boolean };

export function newTranslationState(): TranslationState {
  return { stopped: false };
}

/** 本文と、翻訳に失敗したか（失敗の行の件数に数えるか）。 */
export type BodyResult = { body: PostBody; failed: boolean };

/** 口が約束に反して例外を投げたときも、外との接続の失敗として扱う（D14 の二重の守り）。 */
async function safeTranslate(translator: TranslatePort, text: string, attempt: 1 | 2): Promise<TranslateResult> {
  try {
    return await translator.translate(text, attempt);
  } catch {
    return { ok: false, reason: "failed" };
  }
}

/** 成功した訳文を判定する。訳す必要の無いポストなら印なしの原文、検証を通れば訳文と機械翻訳の印、どちらでもなければ未定。 */
function judgeSuccess(original: string, translated: string): PostBody | undefined {
  // 原文と同じ文字が返ったかを、検証より先に見る（D15）。
  if (isUntranslatedEcho(original, translated)) return { text: original };
  const accepted = acceptTranslation(original, translated);
  return accepted === undefined ? undefined : { text: accepted, mark: MACHINE_TRANSLATED_MARK };
}

/**
 * 通に載せる本文を決める（D1・D5・D15・D21）。訳さないポストは原文のまま、訳せたら訳文に機械翻訳の印、
 * 2 回試して駄目なら原文に失敗の印。2 回とも外との接続の失敗なら、この実行では翻訳を止める。
 * 1 回目が unavailable（手段を使えない）なら、2 回目を試さず待たずに原文に失敗の印を付け、この実行では翻訳を止める。
 * 例外を外へ出さない。
 */
export async function bodyFor(text: string, deps: TryTranslateDeps, state: TranslationState): Promise<BodyResult> {
  if (!needsTranslation(text)) return { body: { text }, failed: false };
  const failed: BodyResult = { body: { text, mark: TRANSLATION_FAILED_MARK }, failed: true };
  if (state.stopped) return failed;

  const first = await safeTranslate(deps.translator, text, 1);
  if (first.ok) {
    const body = judgeSuccess(text, first.text);
    if (body !== undefined) return { body, failed: false };
  } else if (first.reason === "unavailable") {
    state.stopped = true;
    return failed;
  }
  await deps.sleep(TRANSLATE_RETRY_DELAY_MS);
  const second = await safeTranslate(deps.translator, text, 2);
  if (second.ok) {
    const body = judgeSuccess(text, second.text);
    if (body !== undefined) return { body, failed: false };
  }
  // 検証を通らなかっただけのときはポストごとの問題なので止めない。
  if (!first.ok && !second.ok) state.stopped = true;
  return failed;
}

/** 訳だけを試す流れ（D7・D18）。1 行目に結果の種類、続けて本文、印があれば印、最後に所要時間を出す。終了コードは 0。 */
export async function tryTranslate(text: string, deps: TryTranslateDeps): Promise<number> {
  const started = deps.now();
  const { body } = await bodyFor(text, deps, newTranslationState());
  const seconds = (deps.now() - started) / 1000;
  const head =
    body.mark === MACHINE_TRANSLATED_MARK ? TRY_TRANSLATED : body.mark === TRANSLATION_FAILED_MARK ? TRY_TRANSLATION_FAILED : TRY_NOT_TRANSLATED;
  deps.out(head);
  deps.out(body.text);
  if (body.mark !== undefined) deps.out(body.mark);
  deps.out(translationDurationLine(seconds));
  return 0;
}
