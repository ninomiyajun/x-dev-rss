// 試し取得（--dry-run。計画の手順 6・V1）。取得だけを行い、投稿も記録の読み書きもしない。
// --show-text のときだけ、各ポストの行の次に本文の行を出す（D17）。
import { CONFIG_UNREADABLE, fetchFailureLine, formatJst, showTextLine } from "../domain/message.ts";
import { classifyAll, postedAtOf } from "../domain/post.ts";
import type { PostKind } from "../domain/post.ts";
import { rankCounted } from "../domain/select.ts";
import type { StopReason } from "../domain/select.ts";
import type { ConfigPort, FetchPort, LockPort, Output, SecretBundle, SecretsPort } from "./ports.ts";
import { withSession } from "./session.ts";

export type InspectDeps = {
  secrets: SecretsPort;
  lock: LockPort;
  config: ConfigPort;
  makeFetcher(bundle: SecretBundle): FetchPort;
  out: Output;
  /** 各ポストの本文の行も出すか（--show-text。D17）。既定は出さない。 */
  showText?: boolean;
};

const KIND_TEXT: Record<PostKind, string> = {
  own: "通常",
  quote: "引用",
  reply: "返信",
  retweet: "リポスト",
  foreign: "他人のポスト",
};

const STOP_TEXT: Record<StopReason, string> = {
  exhausted: "取得: 並びの終わりまで取得した",
  enough: "取得: 通常のポストが 20 件そろったので途中でやめた",
  limit: "取得: 要求の回数か件数の上限で途中でやめた",
};

export function inspect(deps: InspectDeps): Promise<number> {
  return withSession(deps, async (bundle) => {
    const config = await deps.config.read();
    if (!config.ok) {
      deps.out(CONFIG_UNREADABLE);
      return 1;
    }
    const fetcher = deps.makeFetcher(bundle);
    let code = 0;
    for (const account of config.accounts) {
      const result = await fetcher.fetchAccount(account);
      if (!result.ok) {
        deps.out(fetchFailureLine([{ account, kind: result.kind }]));
        deps.out(`X への要求の回数: ${result.requests}`);
        code = 1;
        continue;
      }
      const classified = classifyAll(result.posts, result.targetUserId);
      const ranks = rankCounted(classified);
      deps.out(`@${account}`);
      for (const c of classified) {
        const rank = ranks.get(c.facts.id);
        deps.out(
          [
            c.facts.id,
            `${formatJst(postedAtOf(c.facts))}（日本時間）`,
            `種類=${KIND_TEXT[c.kind]}`,
            `固定表示=${c.facts.isPinned ? "はい" : "いいえ"}`,
            `順位=${rank === undefined ? "-" : String(rank)}`,
          ].join(" "),
        );
        if (deps.showText === true) deps.out(showTextLine(c.facts.text));
      }
      deps.out(STOP_TEXT[result.stop]);
      deps.out(`X への要求の回数: ${result.requests}`);
    }
    return code;
  });
}
