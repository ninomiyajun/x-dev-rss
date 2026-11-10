// 翻訳の、手段によらない決め（計画 docs/exec-plans/active/2026-11-10-x-post-japanese.md の D1・D6・D15）。
// 訳すかどうかの判定、守る部分（URL・メンション・ハッシュタグ・コード）の取り出し、訳文の検証。入出力を持たない。
// 本文の包みと system prompt は翻訳の手段に固有なので、ここには置かない（D13。外との接続に置く）。

/** 守る部分の種類。 */
type PartKind = "code" | "url" | "mention" | "hashtag";

type Part = { kind: PartKind; text: string; index: number };

// コードを先に試し、その中の URL などを別の守る部分として数えない。
const PART = /(`[^`]+`)|(https?:\/\/[\x21-\x7E]+)|(?<![A-Za-z0-9_])(@[A-Za-z0-9_]+)|(#[\p{L}\p{N}_]+)/gu;
// URL の末尾から除く文字（文の区切りとして URL の直後に書かれることが多いため）。
const URL_TRAILING = /[.,)!?]+$/u;

function parts(text: string): Part[] {
  const found: Part[] = [];
  for (const m of text.matchAll(PART)) {
    const index = m.index;
    if (m[1] !== undefined) found.push({ kind: "code", text: m[1], index });
    else if (m[2] !== undefined) {
      const url = m[2].replace(URL_TRAILING, "");
      // 「https://」の後が末尾の文字だけのときは URL として扱わない。
      if (/^https?:\/\/.+/u.test(url)) found.push({ kind: "url", text: url, index });
    } else if (m[3] !== undefined) found.push({ kind: "mention", text: m[3], index });
    else if (m[4] !== undefined) found.push({ kind: "hashtag", text: m[4], index });
  }
  return found;
}

/** 守る部分の並び（本文に現れる順）。 */
export function protectedParts(text: string): string[] {
  return parts(text).map((p) => p.text);
}

// 絵文字と、絵文字の結合に使う文字（結合子・異体字の選択子・肌の色・キーキャップ・タグ・国旗の地域の文字）。
const EMOJI = /\p{Extended_Pictographic}|\p{Emoji_Modifier}|\p{Regional_Indicator}|\u200D|\uFE0E|\uFE0F|\u20E3|[\u{E0020}-\u{E007F}]/gu;

/** 本文から、各守る部分の先頭の removed(p) 文字と絵文字を除いた残り。 */
function restOf(text: string, removed: (p: Part) => number): string {
  let rest = "";
  let from = 0;
  for (const p of parts(text)) {
    rest += text.slice(from, p.index);
    from = p.index + removed(p);
  }
  rest += text.slice(from);
  return rest.replace(EMOJI, "");
}

/** 訳す文: 本文から守る部分と絵文字を除いた残り。 */
export function translatableText(text: string): string {
  return restOf(text, (p) => p.text.length);
}

const LATIN_WORD = /\p{Script=Latin}+/gu;

/** 訳す文の中のラテン文字の語（数字と日本語は語に数えない）。 */
function latinWords(text: string): string[] {
  return translatableText(text).match(LATIN_WORD) ?? [];
}

/** 訳すか。訳す文にラテン文字の語が 1 つでもあれば true（日本語のポストと、訳す文の無いポストは false）。 */
export function needsTranslation(text: string): boolean {
  return latinWords(text).length > 0;
}

/** 案 A で、原文と同じ文字が返ってよい語数の上限（仕様の XPJA-9・XPJA-10）。 */
export const ECHO_WORD_LIMIT = 4;

/**
 * 訳す必要の無いポストか（案 A。D15）。前後の空白を除いた訳文が原文と同じで、かつ訳す文のラテン文字の語が 4 語以下なら true。
 * true のときは、原文のまま印を付けずに載せる。acceptTranslation より前に判定する。
 */
export function isUntranslatedEcho(original: string, translated: string): boolean {
  return translated.trim() === original.trim() && latinWords(original).length <= ECHO_WORD_LIMIT;
}

const JAPANESE = /[\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Han}]/u;

// 守る部分の直前に来てはいけない文字（D6 の (3)）。
const BEFORE_FORBIDDEN = /[A-Za-z0-9_@#/]/u;
// 訳文の URL の直後に続いてよい、protectedParts が URL の末尾から除く文字の並び。
const URL_TRAILING_PREFIX = /^[.,)!?]+/u;
// 守る部分の直後に来てはいけない文字（その種類の続きに使う ASCII の文字。コードは条件なし）。
// URL は、末尾から除く文字の並びの後の文字で判定する。
const AFTER_FORBIDDEN: Record<PartKind, RegExp | undefined> = {
  url: /[\x21-\x7E]/u,
  mention: /[A-Za-z0-9_]/u,
  hashtag: /[A-Za-z0-9_]/u,
  code: undefined,
};

/** 訳文の中の位置 i から part が現れるとき、その出現が境界の条件を満たすか。 */
function boundedAt(translated: string, part: Part, i: number): boolean {
  const after = AFTER_FORBIDDEN[part.kind];
  const prev = translated[i - 1];
  let end = i + part.text.length;
  // URL は、protectedParts が末尾から除く文字の並びを飛ばして、その後の文字で決める（同じ URL として取り出される出現だけを数える）。
  if (part.kind === "url") end += (translated.slice(end).match(URL_TRAILING_PREFIX)?.[0] ?? "").length;
  const next = translated[end];
  if (prev !== undefined && BEFORE_FORBIDDEN.test(prev)) return false;
  if (next !== undefined && after !== undefined && after.test(next)) return false;
  return true;
}

/** 訳文の中で、境界の条件を満たす part の出現の数。 */
function boundedCount(translated: string, part: Part): number {
  let count = 0;
  for (let i = translated.indexOf(part.text); i !== -1; i = translated.indexOf(part.text, i + 1)) {
    if (boundedAt(translated, part, i)) count++;
  }
  return count;
}

/** 守る部分の同一性・回数・境界（D6 の (3)）。原文の各守る部分が、訳文に境界の条件を満たしてちょうど原文の回数だけある。 */
function keepsProtectedParts(original: string, translated: string): boolean {
  const counts = new Map<string, { part: Part; n: number }>();
  for (const p of parts(original)) {
    const entry = counts.get(p.text);
    if (entry === undefined) counts.set(p.text, { part: p, n: 1 });
    else entry.n++;
  }
  for (const { part, n } of counts.values()) {
    if (boundedCount(translated, part) !== n) return false;
  }
  return true;
}

/**
 * 足された守る部分が無いか（D6 の (4)。D23）。訳文から取り出した守る部分が、どれも原文のどれかの守る部分に境界つきで当たる
 * （訳文の部分がその原文の部分で始まり、その位置の出現が boundedAt の条件を満たす）。原文の部分ごとの回数は (3) が確かめる。
 * 「#AIの」のように、ハッシュタグの直後に空白なしで日本語の文字が続く訳を通すため、完全な一致は求めない。
 */
function noAddedParts(original: string, translated: string): boolean {
  const originals = parts(original);
  return parts(translated).every((t) =>
    originals.some((o) => o.kind === t.kind && t.text.startsWith(o.text) && boundedAt(translated, o, t.index)),
  );
}

/**
 * 訳文の訳す文（D23）。訳文の守る部分が原文の守る部分に境界つきで当たるときは、当たった原文の部分の長さだけを除く
 * （「#AIの更新内容」の「の更新内容」を訳す文に残し、日本語の文字と長さの検証に数えるため）。
 */
function translatedRest(original: string, translated: string): string {
  const originals = parts(original);
  return restOf(translated, (t) => {
    const hits = originals.filter((o) => o.kind === t.kind && t.text.startsWith(o.text) && boundedAt(translated, o, t.index));
    return hits.length === 0 ? t.text.length : Math.max(...hits.map((o) => o.text.length));
  });
}

/** 丸写しの比べのための正規化（D23）: 前後の空白を除き、空白の並び（改行を含む）を 1 つの空白にし、末尾の句読点を除く。 */
function echoKey(text: string): string {
  return text.trim().replace(/\s+/gu, " ").replace(/[.。!?！？]+$/u, "").trimEnd();
}

// 空白だけで区切られて並んだラテン文字の語の連なり。
const LATIN_RUN = /\p{Script=Latin}+(?:\s+\p{Script=Latin}+)*/gu;

/** 訳す文の中の、空白だけで区切られた語の連なりを、小文字にして語の間を 1 つの空白にしたもの。 */
function latinRuns(rest: string): string[][] {
  return (rest.match(LATIN_RUN) ?? []).map((run) => run.toLowerCase().split(/\s+/u));
}

/** 丸写し（D6 の (5)）。原文の訳す文の連続する 5 語の並びが、訳文の訳す文にそのまま現れれば true。引数はどちらも訳す文。 */
function copiesOriginal(originalRest: string, translatedRest: string): boolean {
  const target = latinRuns(translatedRest).map((words) => ` ${words.join(" ")} `);
  for (const words of latinRuns(originalRest)) {
    for (let i = 0; i + 5 <= words.length; i++) {
      const window = ` ${words.slice(i, i + 5).join(" ")} `;
      if (target.some((t) => t.includes(window))) return true;
    }
  }
  return false;
}

const length = (text: string) => Array.from(text).length;

/** 長さ（D6 の (6)）。rest は訳文の訳す文。 */
function hasPlausibleLength(original: string, translated: string, rest: string): boolean {
  const originalTranslatable = length(translatableText(original));
  const minimum = originalTranslatable < 8 ? 1 : originalTranslatable / 8;
  return length(rest) >= minimum && length(translated) <= length(original) * 3 + 200;
}

/**
 * 手段によらない訳文の検証（D6）。isUntranslatedEcho が false のときだけ使う（4 語以下の丸写しの例外はそちらで先に判定する）。
 * 通れば前後の空白を除いた訳文を、通らなければ undefined を返す。形の検査で、訳の意味が正しいことは保証しない。
 */
export function acceptTranslation(original: string, translated: string): string | undefined {
  const text = translated.trim();
  if (text === "") return undefined; // (1)
  if (echoKey(text) === echoKey(original)) return undefined; // (7) 原文と同じ応答（D22・D23）
  const rest = translatedRest(original, text);
  if (!JAPANESE.test(rest)) return undefined; // (2)
  if (!keepsProtectedParts(original, text)) return undefined; // (3)
  if (!noAddedParts(original, text)) return undefined; // (4)
  if (copiesOriginal(translatableText(original), rest)) return undefined; // (5)
  if (!hasPlausibleLength(original.trim(), text, rest)) return undefined; // (6)
  return text;
}
