// 秘匿値のファイルの読み込み（計画の手順 4・D15）。値はどの文面にも入れない。
import { readFile, stat } from "node:fs/promises";
import type { SecretBundle, SecretsPort, SecretsResult } from "../app/ports.ts";

/** 必須の変数（仕様の 4 つ）。 */
export const REQUIRED_SECRETS = ["X_USERNAME", "X_AUTH_TOKEN", "X_CT0", "SLACK_WEBHOOK_URL"] as const;

type SecretName = (typeof REQUIRED_SECRETS)[number];

export type SecretValues = {
  username: string;
  authToken: string;
  ct0: string;
  webhookUrl: string;
};

// 束の中身は、この表の中にだけある（束そのものは中身の無いオブジェクトなので、出力に混ざっても値は出ない）。
const vault = new WeakMap<SecretBundle, SecretValues>();

/** 束の中身を読む。外との接続の部品（取得と投稿）だけが使う。 */
export function openBundle(bundle: SecretBundle): SecretValues {
  const values = vault.get(bundle);
  if (values === undefined) throw new Error("unknown secret bundle");
  return values;
}

/** 試験と入口のための、値から束を作る口。 */
export function makeBundle(values: SecretValues): SecretBundle {
  const bundle = Object.freeze({}) as SecretBundle;
  vault.set(bundle, values);
  return bundle;
}

const WEBHOOK_PREFIX = "https://hooks.slack.com/";
/** Cookie の値に許す形（区切りの文字が混ざって別の Cookie にならないため）。 */
const COOKIE_VALUE = /^[A-Za-z0-9%_-]+$/;

/** KEY=VALUE の行を読む。空行と # の行を飛ばし、値の前後の引用符を外す。シェルの展開はしない。 */
export function parseSecretsText(text: string): SecretsResult {
  const found = new Map<string, string>();
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (line === "" || line.startsWith("#")) continue;
    const body = line.startsWith("export ") ? line.slice("export ".length).trimStart() : line;
    const eq = body.indexOf("=");
    if (eq <= 0) continue;
    const key = body.slice(0, eq).trim();
    let value = body.slice(eq + 1).trim();
    if (value.length >= 2 && (value[0] === '"' || value[0] === "'") && value[value.length - 1] === value[0]) {
      value = value.slice(1, -1);
    }
    found.set(key, value);
  }
  const missing: string[] = REQUIRED_SECRETS.filter((name) => (found.get(name) ?? "") === "");
  const malformed: string[] = [];
  const webhookUrl = found.get("SLACK_WEBHOOK_URL") ?? "";
  if (webhookUrl !== "" && (!webhookUrl.startsWith(WEBHOOK_PREFIX) || /\s/.test(webhookUrl))) {
    malformed.push("SLACK_WEBHOOK_URL");
  }
  for (const name of ["X_AUTH_TOKEN", "X_CT0"] as const) {
    const value = found.get(name) ?? "";
    if (value !== "" && !COOKIE_VALUE.test(value)) malformed.push(name);
  }
  if (missing.length > 0 || malformed.length > 0) return { ok: false, reason: "missing", missing, malformed };
  const get = (name: SecretName) => found.get(name) ?? "";
  return {
    ok: true,
    bundle: makeBundle({
      username: get("X_USERNAME"),
      authToken: get("X_AUTH_TOKEN"),
      ct0: get("X_CT0"),
      webhookUrl: get("SLACK_WEBHOOK_URL"),
    }),
  };
}

/** グループとほかの利用者の権限（どれか 1 つでもあれば止める）。 */
const GROUP_OR_OTHER = 0o077;

export type SecretsFileOptions = {
  /** 実行している利用者の番号（既定は process.getuid）。試験のための口。 */
  uid?: number;
};

/**
 * 秘匿値のファイルを読む口。無いときは 4 つとも足りない扱い。所有者以外にも読める権限なら、中身を読まずに止める。
 * あるのに読めない（権限が無いなど）ときは、無いときと別の結果にする。
 */
export function createSecretsFile(path: string, options: SecretsFileOptions = {}): SecretsPort {
  const uid = options.uid ?? process.getuid?.();
  return {
    async load(): Promise<SecretsResult> {
      let mode: number;
      let owner: number;
      try {
        ({ mode, uid: owner } = await stat(path));
      } catch (err) {
        if ((err as NodeJS.ErrnoException).code === "ENOENT") {
          return { ok: false, reason: "missing", missing: [...REQUIRED_SECRETS], malformed: [] };
        }
        return { ok: false, reason: "unreadable" };
      }
      // 所有者だけの権限で、持ち主が実行している利用者のときだけ読む。
      if ((mode & GROUP_OR_OTHER) !== 0) return { ok: false, reason: "insecure" };
      if (uid !== undefined && owner !== uid) return { ok: false, reason: "foreign-owner" };
      let text: string;
      try {
        text = await readFile(path, "utf8");
      } catch {
        return { ok: false, reason: "unreadable" };
      }
      return parseSecretsText(text);
    },
  };
}
