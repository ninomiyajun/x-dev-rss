// 入口（計画の手順 7・D13）。引数を読み、環境を整え、本物の部品を組み立てて実行の流れに渡す。
// 取得のライブラリを含む src/adapters/x-scraper.ts は、環境変数 DEBUG を消した後に動的に読み込む（静的に読み込まない）。
import { homedir } from "node:os";
import { isAbsolute, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { setTimeout as delay } from "node:timers/promises";
import { inspect } from "./app/inspect.ts";
import { run } from "./app/run.ts";
import type { LockPort, Output, RunDeps } from "./app/ports.ts";
import { createConfigFile } from "./adapters/config.ts";
import { createLockFile } from "./adapters/lock-file.ts";
import { createRecordFile } from "./adapters/record-file.ts";
import { createSecretsFile } from "./adapters/secrets.ts";
import { createSlackPoster } from "./adapters/slack-webhook.ts";
import { DEBUG_REMOVED, NODE_DEBUG_SET, UNEXPECTED_FAILURE } from "./domain/message.ts";

export const USAGE = "使い方: node src/index.ts [--config <パス>] [--state-dir <パス>] [--secrets <パス>] [--dry-run]";

export type Options = { config: string; stateDir: string; secrets: string; dryRun: boolean };

/** 既定の値。記録は $XDG_STATE_HOME/x-dev-rss（無いか絶対パスでなければ ~/.local/state/x-dev-rss）。 */
export function defaultOptions(env: NodeJS.ProcessEnv): Options {
  const home = homedir();
  const xdg = env.XDG_STATE_HOME;
  const stateHome = xdg !== undefined && xdg !== "" && isAbsolute(xdg) ? xdg : join(home, ".local", "state");
  return {
    config: fileURLToPath(new URL("../config/accounts.json", import.meta.url)),
    stateDir: join(stateHome, "x-dev-rss"),
    secrets: join(home, ".config", "x-dev-rss", "secrets.env"),
    dryRun: false,
  };
}

/** 引数を読む。知らない引数や値の無い引数があれば undefined。 */
export function parseArgs(argv: readonly string[], env: NodeJS.ProcessEnv): Options | undefined {
  const options = defaultOptions(env);
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--dry-run") {
      options.dryRun = true;
      continue;
    }
    const key = ({ "--config": "config", "--state-dir": "stateDir", "--secrets": "secrets" } as const)[arg ?? ""];
    const value = argv[i + 1];
    if (key === undefined || value === undefined || value === "") return undefined;
    options[key] = value;
    i++;
  }
  return options;
}

/** 差し替えの口（試験用）。fetch は X と Slack の両方に使う。 */
export type MainOverrides = {
  fetch?: typeof fetch;
  out?: Output;
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
};

// 想定外の失敗のときに外すロック（持っているときだけ）。
let activeLock: LockPort | undefined;

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
  try {
    const { createXFetcher } = await import("./adapters/x-scraper.ts");
    const lock = createLockFile(options.stateDir);
    activeLock = lock;
    const deps: RunDeps = {
      secrets: createSecretsFile(options.secrets),
      lock,
      config: createConfigFile(options.config),
      record: createRecordFile(options.stateDir),
      makeFetcher: (bundle) => createXFetcher(bundle, { fetch: overrides.fetch }),
      makePoster: (bundle) => createSlackPoster(bundle, { fetch: overrides.fetch }),
      sleep: overrides.sleep ?? ((ms) => delay(ms)),
      now: overrides.now ?? (() => Date.now()),
      out,
    };
    const code = options.dryRun ? await inspect(deps) : await run(deps);
    activeLock = undefined;
    return code;
  } catch {
    // 例外の文面は出さない（外から受け取った原文と秘匿値が入りうるため）。
    out(UNEXPECTED_FAILURE);
    await releaseQuietly();
    return 1;
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
    void releaseQuietly().finally(() => process.exit(1));
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
    },
    () => {
      console.error(UNEXPECTED_FAILURE);
      process.exitCode = 1;
    },
  );
}
