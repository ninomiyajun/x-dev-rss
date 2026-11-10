// 試験のための偽物の口と架空の秘匿値。試験のファイルだけが読み込む（アプリのコードからは読み込まない）。
// 架空の値は、16 進数の並びでない、互いに区別できる文字列にしている（ADR 0001 の検出の規則に当たらない形）。
import type { PostFacts } from "../domain/post.ts";
import type { StopReason } from "../domain/select.ts";
import type {
  ConfigPort,
  FetchPort,
  FetchResult,
  LockPort,
  PostPort,
  PostResult,
  RecordPort,
  RecordState,
  RunDeps,
  SecretBundle,
  SecretsPort,
  TranslatePort,
  TranslateResult,
} from "./ports.ts";

export const FAKE_SECRETS = {
  X_USERNAME: "fake_username_qqq",
  X_AUTH_TOKEN: "fake-auth-token-value-zzz",
  X_CT0: "fake-ct0-value-yyy",
  SLACK_WEBHOOK_URL: "https://hooks.slack.com/services/example-fake-webhook-www",
} as const;

export const FAKE_SECRET_VALUES: readonly string[] = Object.values(FAKE_SECRETS);

/** 秘匿値のファイルの中身。値に null を渡した変数は行ごと除く。 */
export function fakeSecretsText(overrides: Partial<Record<keyof typeof FAKE_SECRETS, string | null>> = {}): string {
  const lines: string[] = [];
  for (const [key, value] of Object.entries({ ...FAKE_SECRETS, ...overrides })) {
    if (value !== null) lines.push(`${key}=${value}`);
  }
  return `${lines.join("\n")}\n`;
}

/** 文字列に架空の秘匿値が 1 つでも含まれるか。 */
export function containsSecret(text: string): boolean {
  return FAKE_SECRET_VALUES.some((v) => text.includes(v));
}

export const TARGET_USER_ID = "100";

export function fakePost(id: string | number, extra: Partial<PostFacts> = {}): PostFacts {
  return {
    id: String(id),
    authorId: TARGET_USER_ID,
    authorName: "AnthropicAI",
    isRetweet: false,
    isQuote: false,
    isReply: false,
    isPinned: false,
    postedAt: undefined,
    text: `本文 ${id}`,
    url: `https://x.com/AnthropicAI/status/${id}`,
    ...extra,
  };
}

export function fetched(posts: PostFacts[], stop: StopReason = "exhausted"): FetchResult {
  return { ok: true, targetUserId: TARGET_USER_ID, posts, stop, requests: 2 };
}

/** 取得の口の偽物。アカウントごとに、呼ばれた順に返す結果の並び（最後の結果は繰り返す）。 */
export class FakeFetcher implements FetchPort {
  calls: string[] = [];
  private readonly script: Map<string, FetchResult[]>;
  constructor(script: Record<string, FetchResult | FetchResult[]>) {
    this.script = new Map(Object.entries(script).map(([k, v]) => [k.toLowerCase(), Array.isArray(v) ? v : [v]]));
  }
  set(account: string, results: FetchResult | FetchResult[]): void {
    this.script.set(account.toLowerCase(), Array.isArray(results) ? results : [results]);
  }
  async fetchAccount(account: string): Promise<FetchResult> {
    const list = this.script.get(account.toLowerCase()) ?? [fetched([])];
    const n = this.calls.filter((a) => a.toLowerCase() === account.toLowerCase()).length;
    this.calls.push(account);
    return list[Math.min(n, list.length - 1)] as FetchResult;
  }
}

/** 投稿の口の偽物。受け取った通を順に残す。fail が返す結果で失敗させる。 */
export class FakePoster implements PostPort {
  readonly textLimit: number;
  received: string[] = [];
  attempts: string[] = [];
  fail: (text: string, attempt: number) => PostResult | undefined = () => undefined;
  constructor(textLimit = 40000) {
    this.textLimit = textLimit;
  }
  measure(text: string): number {
    return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").length;
  }
  async post(text: string): Promise<PostResult> {
    const attempt = this.attempts.filter((t) => t === text).length + 1;
    this.attempts.push(text);
    const failure = this.fail(text, attempt);
    if (failure !== undefined) return failure;
    this.received.push(text);
    return { ok: true };
  }
}

/** 記録の口の偽物（手元の表だけに持つ）。 */
export class MemoryRecord implements RecordPort {
  accounts: Map<string, Set<string>> | undefined;
  writes: { account: string; ids: string[] }[] = [];
  /** 書き込みを失敗させる条件（試験用）。 */
  failAdd: (account: string, ids: readonly string[]) => boolean = () => false;
  constructor(initial: Record<string, string[]> | "broken" = {}) {
    this.accounts =
      initial === "broken" ? undefined : new Map(Object.entries(initial).map(([k, v]) => [k.toLowerCase(), new Set(v)]));
  }
  async read(): Promise<RecordState> {
    if (this.accounts === undefined) return { ok: false };
    return { ok: true, accounts: new Map([...this.accounts].map(([k, v]) => [k, new Set(v)])) };
  }
  async add(account: string, ids: readonly string[]): Promise<void> {
    if (this.accounts === undefined) throw new Error("broken");
    if (this.failAdd(account, ids)) throw new Error("write failed");
    const key = account.toLowerCase();
    const set = this.accounts.get(key) ?? new Set<string>();
    for (const id of ids) set.add(id);
    this.accounts.set(key, set);
    this.writes.push({ account, ids: [...ids] });
  }
  ids(account: string): string[] | undefined {
    const set = this.accounts?.get(account.toLowerCase());
    return set === undefined ? undefined : [...set].sort();
  }
}

export class MemoryLock implements LockPort {
  busy = false;
  held = false;
  released = 0;
  async acquire(): Promise<"acquired" | "busy"> {
    if (this.busy) return "busy";
    this.held = true;
    return "acquired";
  }
  async release(): Promise<void> {
    this.held = false;
    this.released++;
  }
}

/** 翻訳の偽物が返すもの。"throw" は、口の約束に反して例外を投げる。 */
export type FakeTranslation = TranslateResult | "throw";

/**
 * 翻訳の口の偽物。呼ばれた本文と回数（attempt）を残す。本文ごと・回数ごとに返す結果を試験が決められる。
 * 決めていない本文には、本文の前に「訳文の」を付けた文を返す。
 */
export class FakeTranslator implements TranslatePort {
  calls: { text: string; attempt: 1 | 2 }[] = [];
  private readonly script = new Map<string, FakeTranslation[]>();
  /** 決めていない本文に返す結果。 */
  fallback: (text: string, attempt: 1 | 2) => FakeTranslation = (text) => ({ ok: true, text: `訳文の${text}` });
  /** 呼ばれたときに、結果を返す前に動かす処理（試験で終了要求の印を立てるなど）。 */
  onCall: (text: string, attempt: 1 | 2) => void = () => {};

  /** 本文に返す結果を、1 回目・2 回目の順に決める（1 つだけなら両方に使う）。 */
  set(text: string, ...results: FakeTranslation[]): void {
    this.script.set(text, results);
  }

  async translate(text: string, attempt: 1 | 2): Promise<TranslateResult> {
    this.calls.push({ text, attempt });
    this.onCall(text, attempt);
    const list = this.script.get(text);
    const result = list === undefined ? this.fallback(text, attempt) : (list[Math.min(attempt, list.length) - 1] as FakeTranslation);
    if (result === "throw") throw new Error(`fake translator failure ${FAKE_SECRETS.X_CT0}`);
    return result;
  }
}

/** 差し替えの待ちと時刻。待つと時刻が進む。 */
export class FakeTime {
  current = 1_800_000_000_000;
  sleeps: number[] = [];
  readonly now = () => this.current;
  readonly sleep = async (ms: number) => {
    this.sleeps.push(ms);
    this.current += ms;
  };
}

const FAKE_BUNDLE = Object.freeze({}) as SecretBundle;

export type Harness = {
  deps: RunDeps;
  fetcher: FakeFetcher;
  poster: FakePoster;
  record: MemoryRecord;
  lock: MemoryLock;
  time: FakeTime;
  translator: FakeTranslator;
  lines: string[];
  fetcherMade: number;
  posterMade: number;
};

export function harness(options: {
  accounts?: string[] | null;
  record?: Record<string, string[]> | "broken";
  fetch?: Record<string, FetchResult | FetchResult[]>;
  secrets?: SecretsPort;
  textLimit?: number;
}): Harness {
  const fetcher = new FakeFetcher(options.fetch ?? {});
  const poster = new FakePoster(options.textLimit);
  const record = new MemoryRecord(options.record ?? {});
  const lock = new MemoryLock();
  const time = new FakeTime();
  const translator = new FakeTranslator();
  const lines: string[] = [];
  const accounts = options.accounts === undefined ? ["AnthropicAI"] : options.accounts;
  const config: ConfigPort = {
    async read() {
      return accounts === null ? { ok: false } : { ok: true, accounts };
    },
  };
  const h: Harness = {
    fetcher,
    poster,
    record,
    lock,
    time,
    translator,
    lines,
    fetcherMade: 0,
    posterMade: 0,
    deps: {
      secrets: options.secrets ?? { load: async () => ({ ok: true, bundle: FAKE_BUNDLE }) },
      lock,
      config,
      record,
      makeFetcher: () => {
        h.fetcherMade++;
        return fetcher;
      },
      makePoster: () => {
        h.posterMade++;
        return poster;
      },
      translator,
      interrupted: () => false,
      sleep: time.sleep,
      now: time.now,
      out: (line) => lines.push(line),
    },
  };
  return h;
}
