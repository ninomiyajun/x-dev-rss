// 候補の選び方（計画の D5）: 数える対象・順位・固定表示・初めての実行・漏れのおそれ・記録する ID と、
// 並びをいつ読み終えるかの決まり（集め役）。入出力を持たない。
import { classifyPost, compareIds, isNotifiedKind, isRecordOnlyKind } from "./post.ts";
import type { ClassifiedPost, PostFacts, PostKind } from "./post.ts";

// ---- 「20 件」の数え方（利用者の決定 2026-11-09: 通常のポストだけで数える）。変えるときに直すのは、この区画だけである ----

/** 1 回の実行で候補にする件数（アカウントあたり）。 */
export const CANDIDATE_LIMIT = 20;

/** 「20 件」に数える種類か。通常のポストだけ（返信・リポスト・引用は数えない）。 */
export function countsTowardLimit(kind: PostKind): boolean {
  return kind === "own";
}
// ---- 「20 件」の区画ここまで ----

/**
 * 取得の止まり方。
 * - exhausted: 並びの終わりまで取得した
 * - enough: 固定表示でない通常のポストが 20 件そろったページを読み切って止めた
 * - limit: 要求の回数か受け取る件数の上限で止まった
 */
export type StopReason = "exhausted" | "enough" | "limit";

/**
 * 並びを読む集め役。受け取ったポストを ID で重複を除いて持ち、固定表示でない通常のポストが 20 件そろったかを答える。
 * そろっても、読んでいるページは読み切ってから止める（並びがページの中で順不同でも、20 位以内を欠かさないため）。
 */
export class TimelineCollector {
  private readonly targetUserId: string;
  private readonly posts: PostFacts[] = [];
  private readonly seen = new Set<string>();
  private counted = 0;

  constructor(targetUserId: string) {
    this.targetUserId = targetUserId;
  }

  add(facts: PostFacts): void {
    if (this.seen.has(facts.id)) return;
    this.seen.add(facts.id);
    this.posts.push(facts);
    if (countsTowardLimit(classifyPost(facts, this.targetUserId).kind) && !facts.isPinned) this.counted++;
  }

  /** 次のページを求めずに止めてよいか。 */
  get enough(): boolean {
    return this.counted >= CANDIDATE_LIMIT;
  }

  collected(): PostFacts[] {
    return [...this.posts];
  }
}

export type Selection = {
  /** 投稿する順（ID の小さい順＝古い順）に並べた候補。 */
  toPost: PostFacts[];
  /** 投稿の前に、投稿しないで記録する ID。 */
  toRecordWithoutPosting: string[];
  /** 取得件数の外へ出て漏れたおそれがあるか（XPOST-20）。 */
  maybeMissed: boolean;
  /** 数える対象の ID → 順位（1 から）。 */
  ranks: Map<string, number>;
};

/** 数える対象を ID の大きい順に並べ、ID → 順位の表を返す。 */
export function rankCounted(posts: readonly ClassifiedPost[]): Map<string, number> {
  const counted = posts.filter((p) => countsTowardLimit(p.kind)).sort((a, b) => compareIds(b.facts.id, a.facts.id));
  const ranks = new Map<string, number>();
  counted.forEach((p, i) => ranks.set(p.facts.id, i + 1));
  return ranks;
}

/**
 * 1 つのアカウントの、その回の候補と記録する ID を決める。
 * @param recorded そのアカウントの記録（項目が無ければ undefined。初めての実行の扱いになる）
 * @param stop 取得の止まり方
 */
export function selectForAccount(
  posts: readonly ClassifiedPost[],
  recorded: ReadonlySet<string> | undefined,
  stop: StopReason,
): Selection {
  const ranks = rankCounted(posts);
  const counted = posts
    .filter((p) => ranks.has(p.facts.id))
    .sort((a, b) => (ranks.get(a.facts.id) ?? 0) - (ranks.get(b.facts.id) ?? 0));
  const top = counted.slice(0, CANDIDATE_LIMIT);
  const threshold = counted.length >= CANDIDATE_LIMIT ? top[top.length - 1]?.facts.id : undefined;

  const recordOnly = posts.filter(
    (p) => isRecordOnlyKind(p.kind) && (threshold === undefined || compareIds(p.facts.id, threshold) >= 0),
  );

  if (recorded === undefined) {
    // 初めての実行: 順位 1 位だけを投稿し、ほかの候補と、記録する範囲の種類で外したものを先に記録する。
    const [first, ...rest] = top;
    return {
      toPost: first === undefined ? [] : [first.facts],
      toRecordWithoutPosting: unique([...rest.map((p) => p.facts.id), ...recordOnly.map((p) => p.facts.id)]),
      maybeMissed: false,
      ranks,
    };
  }

  const toPost = top
    .filter((p) => !recorded.has(p.facts.id) && isNotifiedKind(p.kind))
    .map((p) => p.facts)
    .sort((a, b) => compareIds(a.id, b.id));
  const toRecordWithoutPosting = unique(recordOnly.map((p) => p.facts.id).filter((id) => !recorded.has(id)));

  return { toPost, toRecordWithoutPosting, maybeMissed: maybeMissed(top, recorded, stop), ranks };
}

/**
 * 漏れのおそれ（XPOST-20）。並びの終わりまで取得したなら無い。途中で止めたとき（20 件そろった・上限）は、
 * 取得できた通常のポスト（固定表示を含み、新しいほうから最大 20 件）が、記録に 1 件も無いときに有る。
 * 記録済みの返信・リポスト・引用は判定に数えない。
 */
function maybeMissed(top: readonly ClassifiedPost[], recorded: ReadonlySet<string>, stop: StopReason): boolean {
  if (stop === "exhausted") return false;
  return !top.some((p) => recorded.has(p.facts.id));
}

function unique(ids: string[]): string[] {
  return [...new Set(ids)];
}
