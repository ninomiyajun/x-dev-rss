// 実行の流れが外とやりとりする口の型。外との接続（src/adapters/）が読んでよい app のファイルは、これだけである。
import type { FetchFailureKind } from "../domain/message.ts";
import type { PostFacts } from "../domain/post.ts";
import type { StopReason } from "../domain/select.ts";

declare const secretBundleBrand: unique symbol;

/**
 * 揃った秘匿値の束（計画の D15）。中身の無い型で、実行の流れからは開けない。
 * 中身は src/adapters/secrets.ts の中でだけ読める。
 */
export type SecretBundle = { readonly [secretBundleBrand]: true };

export type SecretsResult =
  | { ok: true; bundle: SecretBundle }
  /** 変数が足りないか形が違う（ファイルが無いときは 4 つとも足りない）。 */
  | { ok: false; reason: "missing"; missing: string[]; malformed: string[] }
  /** ファイルが所有者以外にも読める権限になっている（中身は読まない）。 */
  | { ok: false; reason: "insecure" }
  | { ok: false; reason: "foreign-owner" }
  /** ファイルはあるが読めない（権限が無いなど）。 */
  | { ok: false; reason: "unreadable" };

export interface SecretsPort {
  load(): Promise<SecretsResult>;
}

export type AccountsResult = { ok: true; accounts: string[] } | { ok: false };

export interface ConfigPort {
  read(): Promise<AccountsResult>;
}

/** 記録の読み取りの結果。accounts の鍵は小文字のアカウント名。 */
export type RecordState = { ok: true; accounts: Map<string, Set<string>> } | { ok: false };

export interface RecordPort {
  read(): Promise<RecordState>;
  /** そのアカウントの記録に ID を足して書き込む（ID が空でも、アカウントの項目を作る）。 */
  add(account: string, ids: readonly string[]): Promise<void>;
}

export interface LockPort {
  acquire(): Promise<"acquired" | "busy">;
  release(): Promise<void>;
}

export type FetchFailure = { ok: false; kind: FetchFailureKind; retryable: boolean; requests: number };

export type FetchSuccess = {
  ok: true;
  targetUserId: string;
  /** 受け取った順の、ID で重複を除いたポスト。 */
  posts: PostFacts[];
  /** 取得の止まり方。 */
  stop: StopReason;
  /** X への要求の回数。 */
  requests: number;
};

export type FetchResult = FetchSuccess | FetchFailure;

export interface FetchPort {
  fetchAccount(account: string): Promise<FetchResult>;
}

export type PostResult = { ok: true } | { ok: false; retryable: boolean; retryAfterSeconds?: number };

export interface PostPort {
  /** 1 通の上限の値（D7）。 */
  readonly textLimit: number;
  /** 書き換えた後の長さの測り方（D7）。 */
  measure(text: string): number;
  post(text: string): Promise<PostResult>;
}

export type Sleep = (ms: number) => Promise<void>;
export type Clock = () => number;
export type Output = (line: string) => void;

export type RunDeps = {
  secrets: SecretsPort;
  lock: LockPort;
  config: ConfigPort;
  record: RecordPort;
  makeFetcher(bundle: SecretBundle): FetchPort;
  makePoster(bundle: SecretBundle): PostPort;
  sleep: Sleep;
  now: Clock;
  out: Output;
};
