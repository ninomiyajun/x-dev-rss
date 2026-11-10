// 通常の実行と試し取得に共通の最初の段取り: 秘匿値を読み、ロックを取り、本体を動かし、どの道でもロックを外す。
import { LOCK_BUSY, secretsFailureLine } from "../domain/message.ts";
import type { LockPort, Output, SecretBundle, SecretsPort } from "./ports.ts";

export type SessionDeps = { secrets: SecretsPort; lock: LockPort; out: Output };

/** 秘匿値 → ロック → body → ロックを外す。終了コードを返す。 */
export async function withSession(deps: SessionDeps, body: (bundle: SecretBundle) => Promise<number>): Promise<number> {
  const secrets = await deps.secrets.load();
  if (!secrets.ok) {
    deps.out(secretsFailureLine(secrets));
    return 1;
  }
  if ((await deps.lock.acquire()) === "busy") {
    deps.out(LOCK_BUSY);
    return 0;
  }
  try {
    return await body(secrets.bundle);
  } finally {
    await deps.lock.release();
  }
}
