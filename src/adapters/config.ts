// 対象のアカウントの設定の読み込み（計画の D4）。形: {"accounts": ["AnthropicAI"]}
import { readFile } from "node:fs/promises";
import type { AccountsResult, ConfigPort } from "../app/ports.ts";

const ACCOUNT_NAME = /^[A-Za-z0-9_]{1,15}$/;

/** 設定の中身を読み、名前の先頭の @ を外し、大文字小文字を区別せずに重複を除く。 */
export function parseAccountsConfig(text: string): AccountsResult {
  let data: unknown;
  try {
    data = JSON.parse(text);
  } catch {
    return { ok: false };
  }
  if (typeof data !== "object" || data === null || !("accounts" in data) || !Array.isArray(data.accounts)) {
    return { ok: false };
  }
  const accounts: string[] = [];
  const seen = new Set<string>();
  for (const item of data.accounts as unknown[]) {
    if (typeof item !== "string") return { ok: false };
    const name = item.trim().replace(/^@/, "");
    if (!ACCOUNT_NAME.test(name)) return { ok: false };
    const key = name.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    accounts.push(name);
  }
  if (accounts.length === 0) return { ok: false };
  return { ok: true, accounts };
}

export function createConfigFile(path: string): ConfigPort {
  return {
    async read() {
      try {
        return parseAccountsConfig(await readFile(path, "utf8"));
      } catch {
        return { ok: false };
      }
    },
  };
}
