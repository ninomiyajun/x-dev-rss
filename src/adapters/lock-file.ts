// 2 つの実行が同時に動かないためのロック（計画の D9）。記録のディレクトリに run.lock を置く。
// 中身は「プロセスの番号」と「そのプロセスの開始時刻」の 2 行。両方が一致するときだけ、持ち主が生きているとみなす。
import { link, mkdir, readFile, unlink, writeFile } from "node:fs/promises";
import { createHash, randomBytes } from "node:crypto";
import { execFile } from "node:child_process";
import { join } from "node:path";
import type { LockPort } from "../app/ports.ts";

export const LOCK_FILE_NAME = "run.lock";
/** 開始時刻を得られなかったときに書く印。 */
export const UNKNOWN_START = "unknown";
/** 回収の印を、さらに回収する段の深さの上限。 */
const MAX_RECLAIM_DEPTH = 2;

export type LockOptions = {
  pid?: number;
  /** プロセスの生死を確かめる口（既定は process.kill）。 */
  kill?: (pid: number, signal: 0) => void;
  /** プロセスの開始時刻を得る口（既定は ps -o lstart=）。得られなければ undefined。 */
  startTimeOf?: (pid: number) => Promise<string | undefined>;
};

/** ps の絶対パス（PATH の中の別の ps を使わない）。 */
const PS_PATH = "/bin/ps";

/** ps に渡す環境。ロケールと時間帯で lstart の書式が変わるので、どの実行から読んでも同じ文字列になるよう固定する。 */
export function psEnv(): NodeJS.ProcessEnv {
  return { LC_ALL: "C", TZ: "UTC" };
}

/** ps でプロセスの開始時刻を得る。 */
export function psStartTime(pid: number): Promise<string | undefined> {
  return new Promise((resolve) => {
    execFile(PS_PATH, ["-o", "lstart=", "-p", String(pid)], { timeout: 5000, env: psEnv() }, (err, stdout) => {
      const text = String(stdout ?? "").trim();
      resolve(err || text === "" ? undefined : text);
    });
  });
}

function code(err: unknown): string | undefined {
  return (err as NodeJS.ErrnoException | undefined)?.code;
}

async function readOrUndefined(path: string): Promise<string | undefined> {
  try {
    return await readFile(path, "utf8");
  } catch (err) {
    if (code(err) === "ENOENT") return undefined;
    throw err;
  }
}

async function unlinkQuietly(path: string): Promise<void> {
  try {
    await unlink(path);
  } catch (err) {
    if (code(err) !== "ENOENT") throw err;
  }
}

function digest(text: string): string {
  return createHash("sha256").update(text).digest("hex").slice(0, 16);
}

export function createLockFile(dir: string, options: LockOptions = {}): LockPort {
  const pid = options.pid ?? process.pid;
  const kill = options.kill ?? ((p: number, s: 0) => void process.kill(p, s));
  const startTimeOf = options.startTimeOf ?? psStartTime;
  const lockPath = join(dir, LOCK_FILE_NAME);
  let identity: string | undefined;
  let held = false;

  async function me(): Promise<string> {
    identity ??= `${pid}\n${(await startTimeOf(pid)) ?? UNKNOWN_START}`;
    return identity;
  }

  /** 中身が表す持ち主が生きているか。番号が 1 以上で、生きていて、開始時刻も一致するときだけ true。 */
  async function isAlive(content: string): Promise<boolean> {
    const [pidText = "", start = ""] = content.split("\n");
    if (!/^[0-9]+$/.test(pidText.trim())) return false;
    const owner = Number(pidText.trim());
    if (!Number.isSafeInteger(owner) || owner <= 0) return false;
    try {
      kill(owner, 0);
    } catch (err) {
      if (code(err) !== "EPERM") return false;
    }
    if (start.trim() === "" || start.trim() === UNKNOWN_START) return true;
    const current = await startTimeOf(owner);
    // 開始時刻を得られなかったときは、奪わない側に倒す。
    if (current === undefined) return true;
    return current === start.trim();
  }

  /** path に content の名前を、一時ファイルと link で付ける。付けられたら true、既にあれば false。 */
  async function create(path: string, content: string): Promise<boolean> {
    const tmp = `${path}.${pid}.${randomBytes(6).toString("hex")}.tmp`;
    await writeFile(tmp, content, { mode: 0o600, flag: "wx" });
    try {
      await link(tmp, path);
      return true;
    } catch (err) {
      if (code(err) === "EEXIST") return false;
      throw err;
    } finally {
      await unlinkQuietly(tmp);
    }
  }

  /**
   * path の中身がまだ stale であれば消す。消せるのは、stale から作った名前の回収の印を取れた実行だけ。
   * 印の持ち主が古ければ、同じ手順で印を回収する（depth 段まで）。消したら true。
   */
  async function reclaim(path: string, stale: string, depth: number): Promise<boolean> {
    const mark = `${path}.reclaim.${digest(stale)}`;
    const mine = await me();
    if (!(await create(mark, mine))) {
      const holder = await readOrUndefined(mark);
      if (holder === undefined || (await isAlive(holder)) || depth >= MAX_RECLAIM_DEPTH) return false;
      if (!(await reclaim(mark, holder, depth + 1))) return false;
      if (!(await create(mark, mine))) return false;
    }
    try {
      // 印を持っている間は、ほかの実行がこの中身の path を消せないので、読んでから消すまでに中身は変わらない。
      if ((await readOrUndefined(path)) !== stale) return false;
      await unlinkQuietly(path);
      return true;
    } finally {
      if ((await readOrUndefined(mark)) === mine) await unlinkQuietly(mark);
    }
  }

  async function attempt(retried: boolean): Promise<"acquired" | "busy"> {
    await mkdir(dir, { recursive: true, mode: 0o700 });
    const mine = await me();
    if (await create(lockPath, mine)) {
      if ((await readOrUndefined(lockPath)) === mine) {
        held = true;
        return "acquired";
      }
      return "busy";
    }
    const content = await readOrUndefined(lockPath);
    if (content === undefined) return retried ? "busy" : attempt(true);
    if (await isAlive(content)) return "busy";
    if (retried) return "busy";
    if (!(await reclaim(lockPath, content, 0))) return "busy";
    return attempt(true);
  }

  return {
    acquire: () => attempt(false),
    async release() {
      if (!held) return;
      held = false;
      if ((await readOrUndefined(lockPath)) === (await me())) await unlinkQuietly(lockPath);
    },
  };
}
