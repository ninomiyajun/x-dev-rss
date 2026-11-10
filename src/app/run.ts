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
} from "../domain/message.ts";
import type { AccountFailure } from "../domain/message.ts";
import { classifyAll } from "../domain/post.ts";
import { selectForAccount } from "../domain/select.ts";
import type { RunDeps } from "./ports.ts";
import { fetchWithRetry, PacedPoster } from "./retry.ts";
import { withSession } from "./session.ts";

/** 1 回の実行。終了コードを返す（取得・設定・記録・投稿の失敗があれば 1、ほかは 0）。 */
export function run(deps: RunDeps): Promise<number> {
  return withSession(deps, async (bundle) => {
    const poster = new PacedPoster(deps.makePoster(bundle), deps.sleep, deps.now);
    const fetcher = deps.makeFetcher(bundle);

    const config = await deps.config.read();
    if (!config.ok) {
      await poster.post(CONFIG_UNREADABLE);
      deps.out(CONFIG_UNREADABLE);
      return 1;
    }
    const record = await deps.record.read();
    if (!record.ok) {
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
      const result = await fetchWithRetry(() => fetcher.fetchAccount(account), deps.sleep);
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
        if (!(await write(account, selection.toRecordWithoutPosting))) return 1;
      }
      for (const post of selection.toPost) {
        const sent = await poster.post(postMessage(post, account, poster.textLimit, (t) => poster.measure(t)));
        if (!sent.ok) {
          deps.out(postFailedLine(posted));
          return 1;
        }
        posted++;
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
      const sent = await poster.post(s.text);
      if (s.line !== "") deps.out(s.line);
      if (!sent.ok) {
        deps.out(postFailedLine(posted));
        return 1;
      }
    }
    deps.out(countLine(posted));
    return failures.length > 0 ? 1 : 0;
  });
}
