// 1 回の実行の順序（計画の手順 6）。外とのやりとり・待ち・時刻は口を通す。
import {
  CONFIG_UNREADABLE,
  countLine,
  fetchFailureLine,
  fetchFailureMessage,
  maybeMissedMessage,
  noNewPostsMessage,
  postFailedLine,
  postMessage,
  RECORD_UNREADABLE,
  RECORD_WRITE_FAILED,
  translationFailedLine,
} from "../domain/message.ts";
import type { AccountFailure } from "../domain/message.ts";
import { classifyAll } from "../domain/post.ts";
import { selectForAccount } from "../domain/select.ts";
import type { RunDeps } from "./ports.ts";
import { fetchWithRetry, PacedPoster } from "./retry.ts";
import { withSession } from "./session.ts";
import { bodyFor, newTranslationState } from "./translate.ts";

/** 終了要求で止めたときに本体が返す値。入口が終了コード 130 か 143 で上書きするので意味を持たない（D14）。 */
const INTERRUPTED_CODE = 0;

/**
 * 1 回の実行。終了コードを返す（取得・設定・記録・投稿の失敗があれば 1、ほかは 0。翻訳の失敗では 1 にしない）。
 * 終了要求の印が立ったら、以後の取得・記録の書き込み・投稿・まとめの通・件数の行を行わずに戻る（D14）。
 * ただし、送信を終えた投稿の記録は書く（入口が待つのは、送信中の投稿とその後の記録の書き込みのため）。
 */
export function run(deps: RunDeps): Promise<number> {
  return withSession(deps, async (bundle) => {
    const poster = new PacedPoster(deps.makePoster(bundle), deps.sleep, deps.now, deps.interrupted);
    const fetcher = deps.makeFetcher(bundle);
    const translation = newTranslationState();
    let translationFailures = 0;
    /** 翻訳の失敗が 1 件以上あれば、その 1 行を出す（XPJA-3）。 */
    const reportTranslationFailures = () => {
      if (translationFailures > 0) deps.out(translationFailedLine(translationFailures));
    };

    const config = await deps.config.read();
    if (!config.ok) {
      if (deps.interrupted()) return INTERRUPTED_CODE;
      await poster.post(CONFIG_UNREADABLE);
      deps.out(CONFIG_UNREADABLE);
      return 1;
    }
    const record = await deps.record.read();
    if (!record.ok) {
      if (deps.interrupted()) return INTERRUPTED_CODE;
      await poster.post(RECORD_UNREADABLE);
      deps.out(RECORD_UNREADABLE);
      return 1;
    }

    let posted = 0;
    const failures: AccountFailure[] = [];
    const missed: string[] = [];
    const succeeded: string[] = [];

    /**
     * 記録に書き込む。失敗したら知らせて false（XPOST-24）。
     * 止めると後の知らせは送れないので、それまでに集めた漏れのおそれと取得の失敗を同じ 1 通に入れる（XPOST-23）。
     */
    const write = async (account: string, ids: readonly string[]): Promise<boolean> => {
      try {
        await deps.record.add(account, ids);
        return true;
      } catch {
        reportTranslationFailures();
        const texts = [RECORD_WRITE_FAILED];
        const lines = [RECORD_WRITE_FAILED];
        if (missed.length > 0) {
          texts.push(maybeMissedMessage(missed));
          lines.push(maybeMissedMessage(missed));
        }
        if (failures.length > 0) {
          texts.push(fetchFailureMessage(failures));
          lines.push(fetchFailureLine(failures));
        }
        for (const line of lines) deps.out(line);
        await poster.post(texts.join("\n"));
        return false;
      }
    };

    for (const account of config.accounts) {
      if (deps.interrupted()) return INTERRUPTED_CODE;
      const result = await fetchWithRetry(() => fetcher.fetchAccount(account), deps.sleep, deps.interrupted);
      if (!result.ok) {
        failures.push({ account, kind: result.kind });
        continue;
      }
      succeeded.push(account);
      const recorded = record.accounts.get(account.toLowerCase());
      const selection = selectForAccount(classifyAll(result.posts, result.targetUserId), recorded, result.stop);
      if (selection.maybeMissed) missed.push(account);
      // 投稿しないと決めた ID を先に記録する。初めての実行では、ID が無くてもアカウントの項目を作る。
      if (recorded === undefined || selection.toRecordWithoutPosting.length > 0) {
        if (deps.interrupted()) return INTERRUPTED_CODE;
        if (!(await write(account, selection.toRecordWithoutPosting))) return 1;
      }
      for (const post of selection.toPost) {
        if (deps.interrupted()) return INTERRUPTED_CODE;
        const { body, failed } = await bodyFor(post.text, deps, translation);
        if (deps.interrupted()) return INTERRUPTED_CODE;
        if (failed) translationFailures++;
        const sent = await poster.post(postMessage(post, body, account, poster.textLimit, (t) => poster.measure(t)));
        if (!sent.ok) {
          // 再試行の待ちの間に終了要求を受けて止めたときは、失敗の行を出さない。
          if (deps.interrupted()) return INTERRUPTED_CODE;
          reportTranslationFailures();
          deps.out(postFailedLine(posted));
          return 1;
        }
        posted++;
        // 送信を終えた投稿は、終了要求を受けていても記録する（次の実行で二重に通知しないため。D14）。
        if (!(await write(account, [post.id]))) return 1;
      }
    }

    const summaries: { text: string; line: string }[] = [];
    if (missed.length > 0) summaries.push({ text: maybeMissedMessage(missed), line: maybeMissedMessage(missed) });
    if (failures.length > 0) summaries.push({ text: fetchFailureMessage(failures), line: fetchFailureLine(failures) });
    // 漏れのおそれを知らせた回は、「新しいポストはありません」を送らない。
    if (posted === 0 && failures.length === 0 && missed.length === 0) {
      summaries.push({ text: noNewPostsMessage(succeeded), line: "" });
    }
    for (const s of summaries) {
      if (deps.interrupted()) return INTERRUPTED_CODE;
      const sent = await poster.post(s.text);
      if (!sent.ok && deps.interrupted()) return INTERRUPTED_CODE;
      if (s.line !== "") deps.out(s.line);
      if (!sent.ok) {
        reportTranslationFailures();
        deps.out(postFailedLine(posted));
        return 1;
      }
    }
    reportTranslationFailures();
    deps.out(countLine(posted));
    return failures.length > 0 ? 1 : 0;
  });
}
