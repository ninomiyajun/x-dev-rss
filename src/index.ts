// 入口（計画の手順 7・D13・D14）。引数を読み、環境を整え、本物の部品を組み立てて実行の流れに渡す。
// 終了要求（SIGTERM・SIGINT）を受けたら、翻訳の子を止め、実行の流れを上限つきで待ち、ロックを外して終わる。
// 取得のライブラリを含む src/adapters/x-scraper.ts は、環境変数 DEBUG を消した後に動的に読み込む（静的に読み込まない）。
import { homedir } from "node:os";
import { isAbsolute, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { setTimeout as delay } from "node:timers/promises";
import { inspect } from "./app/inspect.ts";
import { run } from "./app/run.ts";
import { tryTranslate } from "./app/translate.ts";
import type { FetchPort, LockPort, Output, RunDeps } from "./app/ports.ts";
import { createClaudeTranslator } from "./adapters/claude-translator.ts";
import type { ClaudeTranslator } from "./adapters/claude-translator.ts";
import { createConfigFile } from "./adapters/config.ts";
import { createLockFile } from "./adapters/lock-file.ts";
import { createRecordFile } from "./adapters/record-file.ts";
import { createSecretsFile } from "./adapters/secrets.ts";
import { createSlackPoster } from "./adapters/slack-webhook.ts";
import { DEBUG_REMOVED, INTERRUPTED, NODE_DEBUG_SET, tryTranslateTooLongLine, UNEXPECTED_FAILURE } from "./domain/message.ts";

export const USAGE =
  "使い方: node src/index.ts [--config <パス>] [--state-dir <パス>] [--secrets <パス>] [--claude <絶対パス>] [--dry-run [--show-text]]" +
  "（訳だけを試すとき: node src/index.ts --try-translate [--claude <絶対パス>] < 本文のファイル）";

/** claude の既定のパス（D2）。launchd の既定の PATH に無い見込みなので、PATH から探さず絶対パスで持つ。 */
export const DEFAULT_CLAUDE_PATH = "/opt/homebrew/bin/claude";
/** --try-translate が標準入力から受け取る本文の上限の文字数（D7）。 */
export const TRY_TRANSLATE_MAX_CHARS = 100_000;
/**
 * 終了要求の後に実行の流れを待つ上限（D14）。Slack への投稿の時間切れ 15 秒（src/adapters/slack-webhook.ts の TIMEOUT_MS）に
 * 5 秒を足した値で、送信中の 1 回分の投稿とその後の記録の書き込みを待つ。
 */
export const INTERRUPT_WAIT_MS = 20_000;
/** 終了要求で止めたときの終了コード（D14）。 */
export const INTERRUPT_EXIT_CODES = { SIGINT: 130, SIGTERM: 143 } as const;

export type Options = {
  config: string;
  stateDir: string;
  secrets: string;
  claude: string;
  dryRun: boolean;
  showText: boolean;
  tryTranslate: boolean;
};

/** 既定の値。記録は $XDG_STATE_HOME/x-dev-rss（無いか絶対パスでなければ ~/.local/state/x-dev-rss）。 */
export function defaultOptions(env: NodeJS.ProcessEnv): Options {
  const home = homedir();
  const xdg = env.XDG_STATE_HOME;
  const stateHome = xdg !== undefined && xdg !== "" && isAbsolute(xdg) ? xdg : join(home, ".local", "state");
  return {
    config: fileURLToPath(new URL("../config/accounts.json", import.meta.url)),
    stateDir: join(stateHome, "x-dev-rss"),
    secrets: join(home, ".config", "x-dev-rss", "secrets.env"),
    claude: DEFAULT_CLAUDE_PATH,
    dryRun: false,
    showText: false,
    tryTranslate: false,
  };
}

/**
 * 引数を読む。知らない引数や値の無い引数、絶対パスでない --claude、--dry-run の無い --show-text、
 * --dry-run と一緒の --try-translate があれば undefined。
 */
export function parseArgs(argv: readonly string[], env: NodeJS.ProcessEnv): Options | undefined {
  const options = defaultOptions(env);
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i] ?? "";
    const flag = ({ "--dry-run": "dryRun", "--show-text": "showText", "--try-translate": "tryTranslate" } as const)[arg];
    if (flag !== undefined) {
      options[flag] = true;
      continue;
    }
    const key = ({ "--config": "config", "--state-dir": "stateDir", "--secrets": "secrets", "--claude": "claude" } as const)[arg];
    const value = argv[i + 1];
    if (key === undefined || value === undefined || value === "") return undefined;
    options[key] = value;
    i++;
  }
  if (!isAbsolute(options.claude)) return undefined;
  if (options.showText && !options.dryRun) return undefined;
  if (options.tryTranslate && options.dryRun) return undefined;
  return options;
}

/** 差し替えの口（試験用）。fetch は X と Slack の両方に使う。 */
export type MainOverrides = {
  fetch?: typeof fetch;
  out?: Output;
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
  /**
   * 取得の口（試験用。指定が無ければ本物の取得の部品を使う）。fetch の差し替えは、本物の取得の部品を通して
   * X との通信の中身（応答の形・失敗）を試すときに使う。この口は、取得の部品ごと替えて、決まったポストを
   * 実行の流れへ渡したいとき（翻訳・終了要求の試験など、X の応答の作りに関わらない試験）に使う。
   */
  fetcher?: FetchPort;
  /** 翻訳の部品の作業ディレクトリの置き場と停止の猶予（試験用。既定は部品の既定）。 */
  claudeWorkRoot?: string;
  claudeGraceMs?: number;
};

// 想定外の失敗のときに外すロック（持っているときだけ）。
let activeLock: LockPort | undefined;
// 終了要求と想定外の失敗のときに止める翻訳の部品（組み立てた後だけ）。
let activeTranslator: ClaudeTranslator | undefined;
// 2 回目の終了要求ですぐに終わる前に、子へ SIGKILL を送る翻訳の部品（1 回目の終了要求の後も持ち続ける）。
let killableTranslator: ClaudeTranslator | undefined;

/** 標準入力を文字列で読む。上限の文字数を超えたら undefined（超えた時点で読むのをやめる）。 */
async function readStdinText(maxChars: number): Promise<string | undefined> {
  const chunks: Buffer[] = [];
  let bytes = 0;
  for await (const chunk of process.stdin) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk));
    bytes += buffer.length;
    // UTF-8 の 1 文字は 4 バイトまでなので、これを超えたら必ず上限を超える。
    if (bytes > maxChars * 4) return undefined;
    chunks.push(buffer);
  }
  const text = Buffer.concat(chunks).toString("utf8");
  return Array.from(text).length > maxChars ? undefined : text;
}

/** promise が終わるか ms が過ぎるまで待つ（失敗は捨てる）。 */
async function waitAtMost(promise: Promise<unknown>, ms: number): Promise<void> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  await Promise.race([promise.catch(() => undefined), new Promise<void>((done) => (timer = setTimeout(done, ms)))]);
  clearTimeout(timer);
}

/**
 * work を動かし、その間の終了要求を受け止める（D14）。終了要求を受けたら、印を立てる → 翻訳の子を止める →
 * work を上限つきで待つ → ロックを外す → INTERRUPTED の 1 行を出し、終了コード 130（SIGINT）か 143（SIGTERM）を返す。
 * 2 回目の終了要求では、待たずにすぐに終わる。
 */
async function runInterruptible(work: () => Promise<number>, interruption: { requested: boolean }, out: Output): Promise<number> {
  let finishInterrupt: (code: number) => void = () => {};
  const interrupted = new Promise<number>((done) => (finishInterrupt = done));
  let running: Promise<number> = Promise.resolve(0);
  const onSignal = (signal: keyof typeof INTERRUPT_EXIT_CODES) => {
    const code = INTERRUPT_EXIT_CODES[signal];
    if (interruption.requested) {
      // 待たずに終わる。止めている途中の子が残らないよう、先に同期で SIGKILL を送る（D14）。
      killTranslatorNow();
      process.exit(code);
    }
    interruption.requested = true;
    void (async () => {
      await stopTranslatorQuietly();
      await waitAtMost(running, INTERRUPT_WAIT_MS);
      await releaseQuietly();
      out(INTERRUPTED);
      finishInterrupt(code);
    })();
  };
  process.on("SIGINT", onSignal);
  process.on("SIGTERM", onSignal);
  try {
    running = work();
    const code = await Promise.race([running, interrupted]);
    // 実行の流れが印を見て先に戻っても、終了要求の処理が終わるのを待つ。
    return interruption.requested ? await interrupted : code;
  } finally {
    process.off("SIGINT", onSignal);
    process.off("SIGTERM", onSignal);
  }
}

export async function main(argv: readonly string[], env: NodeJS.ProcessEnv, overrides: MainOverrides = {}): Promise<number> {
  const out = overrides.out ?? ((line: string) => console.log(line));
  const options = parseArgs(argv, env);
  if (options === undefined) {
    out(USAGE);
    return 2;
  }
  // Node.js の fetch の記録（NODE_DEBUG=fetch など）は送り先のパスを出すので、秘匿値を読む前に止める。
  if ((env.NODE_DEBUG ?? "") !== "" || (process.env.NODE_DEBUG ?? "") !== "") {
    out(NODE_DEBUG_SET);
    return 1;
  }
  if (env.DEBUG !== undefined || process.env.DEBUG !== undefined) {
    delete env.DEBUG;
    delete process.env.DEBUG;
    out(DEBUG_REMOVED);
  }
  const sleep = overrides.sleep ?? ((ms: number) => delay(ms));
  const now = overrides.now ?? (() => Date.now());
  const interruption = { requested: false };
  try {
    let work: () => Promise<number>;
    if (options.tryTranslate) {
      // 秘匿値・ロック・記録・X・Slack を使わない（D7）。
      const text = await readStdinText(TRY_TRANSLATE_MAX_CHARS);
      if (text === undefined) {
        out(tryTranslateTooLongLine(TRY_TRANSLATE_MAX_CHARS));
        return 2;
      }
      const translator = makeTranslator(options.claude, env, overrides);
      work = () => tryTranslate(text, { translator, sleep, now, out });
    } else {
      const { createXFetcher } = await import("./adapters/x-scraper.ts");
      const lock = createLockFile(options.stateDir);
      activeLock = lock;
      const deps: RunDeps = {
        secrets: createSecretsFile(options.secrets),
        lock,
        config: createConfigFile(options.config),
        record: createRecordFile(options.stateDir),
        makeFetcher: (bundle) => overrides.fetcher ?? createXFetcher(bundle, { fetch: overrides.fetch }),
        makePoster: (bundle) => createSlackPoster(bundle, { fetch: overrides.fetch }),
        translator: makeTranslator(options.claude, env, overrides),
        interrupted: () => interruption.requested,
        sleep,
        now,
        out,
      };
      work = () => (options.dryRun ? inspect({ ...deps, showText: options.showText }) : run(deps));
    }
    const code = await runInterruptible(work, interruption, out);
    activeLock = undefined;
    activeTranslator = undefined;
    killableTranslator = undefined;
    return code;
  } catch {
    // 例外の文面は出さない（外から受け取った原文と秘匿値が入りうるため）。
    out(UNEXPECTED_FAILURE);
    await stopTranslatorQuietly();
    await releaseQuietly();
    return 1;
  }
}

/** 翻訳の部品を組み立て、終了要求と想定外の失敗のときに止められるよう覚えておく。 */
function makeTranslator(claudePath: string, env: NodeJS.ProcessEnv, overrides: MainOverrides): ClaudeTranslator {
  const translator = createClaudeTranslator({ claudePath, env, workRoot: overrides.claudeWorkRoot, graceMs: overrides.claudeGraceMs });
  activeTranslator = translator;
  killableTranslator = translator;
  return translator;
}

/** 起動中の翻訳の子のまとまりへ、同期で SIGKILL を送る（終わるのは待たない）。例外を外へ出さない。 */
function killTranslatorNow(): void {
  try {
    killableTranslator?.killAllNow();
  } catch {
    // 部品は例外を外へ出さない作りだが、念のため受け止める。
  }
}

/** 起動中の翻訳の子を止める（以後、部品は新しい子を起動しない）。止める処理は 1 回だけ動く。 */
async function stopTranslatorQuietly(): Promise<void> {
  const translator = activeTranslator;
  activeTranslator = undefined;
  try {
    await translator?.stopAll();
  } catch {
    // 部品は例外を外へ出さない作りだが、念のため受け止める。
  }
}

async function releaseQuietly(): Promise<void> {
  const lock = activeLock;
  activeLock = undefined;
  try {
    await lock?.release();
  } catch {
    // 外せなくても、次の実行が古いロックとして扱う。
  }
}

/** 受け止められていない例外と Promise の失敗で、決まった 1 行だけを出して終了コード 1 で終わる。 */
export function installCrashHandlers(out: Output = (line) => console.error(line)): void {
  const onCrash = () => {
    out(UNEXPECTED_FAILURE);
    // ロックを外す前に、翻訳の子を止める（D14）。
    void stopTranslatorQuietly()
      .then(releaseQuietly)
      .finally(() => process.exit(1));
  };
  process.on("uncaughtException", onCrash);
  process.on("unhandledRejection", onCrash);
}

const invokedDirectly = process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;
if (invokedDirectly) {
  installCrashHandlers();
  main(process.argv.slice(2), process.env).then(
    (code) => {
      process.exitCode = code;
      // 終了要求で止めたときは、上限を超えて残った処理（送信中の投稿など）を待たずに、出力を書き終えてから終える（D14）。
      if (code === INTERRUPT_EXIT_CODES.SIGINT || code === INTERRUPT_EXIT_CODES.SIGTERM) process.stdout.write("", () => process.exit(code));
    },
    () => {
      console.error(UNEXPECTED_FAILURE);
      process.exitCode = 1;
    },
  );
}
