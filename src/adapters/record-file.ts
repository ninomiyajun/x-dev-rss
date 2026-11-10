// 通知済みの記録のファイル（計画の D2・D3）。
// 形: {"version": 1, "accounts": {"<小文字のアカウント名>": {"ids": ["<ID>", …]}}}
import { mkdir, open, readFile, rename, unlink } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import { join } from "node:path";
import type { RecordPort, RecordState } from "../app/ports.ts";

export const RECORD_FILE_NAME = "notified.json";
const VERSION = 1;
const DECIMAL_ID = /^[0-9]+$/;

/** 記録の中身を確かめて読む。形が違えば読めない扱い。 */
export function parseRecord(text: string): RecordState {
  let data: unknown;
  try {
    data = JSON.parse(text);
  } catch {
    return { ok: false };
  }
  if (typeof data !== "object" || data === null || Array.isArray(data)) return { ok: false };
  const obj = data as Record<string, unknown>;
  if (obj.version !== VERSION) return { ok: false };
  const accounts = obj.accounts;
  if (typeof accounts !== "object" || accounts === null || Array.isArray(accounts)) return { ok: false };
  const result = new Map<string, Set<string>>();
  for (const [name, entry] of Object.entries(accounts as Record<string, unknown>)) {
    if (typeof entry !== "object" || entry === null) return { ok: false };
    const ids = (entry as Record<string, unknown>).ids;
    if (!Array.isArray(ids) || !ids.every((id) => typeof id === "string" && DECIMAL_ID.test(id))) return { ok: false };
    // 小文字にそろえると同じ名前になるアカウントが 2 つあれば、どちらが正しいか決まらないので壊れているとする。
    if (result.has(name.toLowerCase())) return { ok: false };
    result.set(name.toLowerCase(), new Set(ids as string[]));
  }
  return { ok: true, accounts: result };
}

function serialize(accounts: Map<string, Set<string>>): string {
  const out: Record<string, { ids: string[] }> = {};
  for (const [name, ids] of [...accounts].sort(([a], [b]) => a.localeCompare(b))) out[name] = { ids: [...ids] };
  return `${JSON.stringify({ version: VERSION, accounts: out }, null, 2)}\n`;
}

/**
 * 記録の口。read で読んだ中身を手元に持ち、add のたびに全体を一時ファイルへ書いてから名前を変える。
 * read が「読めない」を返した後は、add で書き込まない（壊れた記録を上書きしない）。
 */
export type RecordFileOptions = {
  /** 試験のための口: 名前の変更（既定は fs の rename）。 */
  rename?: (from: string, to: string) => Promise<void>;
};

/** 一時ファイルに書いて fsync し、名前を変える。失敗したら一時ファイルを消して例外を投げ直す。 */
async function writeAtomically(path: string, dir: string, text: string, doRename: (from: string, to: string) => Promise<void>) {
  const tmp = join(dir, `${RECORD_FILE_NAME}.${randomBytes(6).toString("hex")}.tmp`);
  try {
    const handle = await open(tmp, "wx", 0o600);
    try {
      await handle.writeFile(text);
      await handle.sync();
    } finally {
      await handle.close();
    }
    await doRename(tmp, path);
  } catch (err) {
    await unlink(tmp).catch(() => undefined);
    throw err;
  }
  await syncDirectory(dir);
}

/** 名前の変更を確実に残すため、置き場のディレクトリを fsync する（失敗しても止めない）。 */
async function syncDirectory(dir: string): Promise<void> {
  try {
    const handle = await open(dir, "r");
    try {
      await handle.sync();
    } finally {
      await handle.close();
    }
  } catch {
    // ディレクトリの fsync ができない環境でも、書き込みそのものは済んでいる。
  }
}

export function createRecordFile(dir: string, options: RecordFileOptions = {}): RecordPort {
  const doRename = options.rename ?? rename;
  const path = join(dir, RECORD_FILE_NAME);
  let state: Map<string, Set<string>> | undefined;
  return {
    async read() {
      let text: string;
      try {
        text = await readFile(path, "utf8");
      } catch (err) {
        if ((err as NodeJS.ErrnoException).code === "ENOENT") {
          state = new Map();
          return { ok: true, accounts: new Map() };
        }
        return { ok: false };
      }
      const parsed = parseRecord(text);
      state = parsed.ok ? parsed.accounts : undefined;
      return parsed.ok ? { ok: true, accounts: cloneAccounts(parsed.accounts) } : parsed;
    },
    async add(account, ids) {
      if (state === undefined) throw new Error("record is not readable");
      // 複製に足して書き、書けたときだけ手元の状態を差し替える（失敗した ID を手元に残さない）。
      const key = account.toLowerCase();
      const next = cloneAccounts(state);
      const set = next.get(key) ?? new Set<string>();
      for (const id of ids) set.add(id);
      next.set(key, set);
      await mkdir(dir, { recursive: true, mode: 0o700 });
      await writeAtomically(path, dir, serialize(next), doRename);
      state = next;
    },
  };
}

function cloneAccounts(accounts: Map<string, Set<string>>): Map<string, Set<string>> {
  return new Map([...accounts].map(([k, v]) => [k, new Set(v)]));
}
