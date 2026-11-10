// V3: 依存の向きの決まりを lint が守らせることを、ESLint の API で確かめる。
import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { ESLint } from "eslint";

const root = fileURLToPath(new URL("..", import.meta.url));
const eslint = new ESLint({ cwd: root });

async function restricted(filePath: string, source: string): Promise<boolean> {
  const [result] = await eslint.lintText(`${source}\nexport {};\n`, { filePath });
  return (result?.messages ?? []).some((m) => m.ruleId === "no-restricted-imports" || m.ruleId === "@typescript-eslint/no-restricted-imports");
}

/** 子プロセスの 2 つの名前の読み込みを、各ファイルについて並べる。 */
function childProcess(files: string[]): [string, string][] {
  return files.flatMap((file): [string, string][] => [
    [file, 'import "node:child_process";'],
    [file, 'import "child_process";'],
  ]);
}

const violations: [string, string][] = [
  ["src/domain/x.ts", 'import "../adapters/secrets.ts";'],
  ["src/domain/x.ts", 'import "../app/ports.ts";'],
  ["src/domain/x.ts", 'import "node:fs";'],
  ["src/app/x.ts", 'import "../adapters/config.ts";'],
  ["src/app/x.ts", 'import "@the-convocation/twitter-scraper";'],
  ["src/app/x.ts", 'import "node:fs";'],
  ["src/app/x.ts", 'import "fs";'],
  ["src/app/x.ts", 'import "node:timers/promises";'],
  ["src/adapters/x.ts", 'import "../app/run.ts";'],
  ["src/adapters/slack-webhook.ts", 'import "@the-convocation/twitter-scraper";'],
  ["src/adapters/slack-webhook.ts", 'import "./x-scraper.ts";'],
  ["src/adapters/sub/x.ts", 'import { TIMELINE } from "../x-scraper.ts";\nvoid TIMELINE;'],
  // 相対パスの深さによらず効く
  ["src/domain/sub/x.ts", 'import "../../adapters/secrets.ts";'],
  ["src/app/sub/x.ts", 'import "../../adapters/config.ts";'],
  ["src/adapters/sub/x.ts", 'import "../../app/run.ts";'],
  ["src/domain/x.ts", 'import "../index.ts";'],
  // 入口は x-scraper を静的に読み込まない
  ["src/index.ts", 'import "./adapters/x-scraper.ts";'],
  ["src/index.ts", 'import "@the-convocation/twitter-scraper";'],
  // V5: 子プロセスを起動してよいのは claude-translator.ts と lock-file.ts だけ（計画の D11）
  ...childProcess(["src/adapters/slack-webhook.ts", "src/adapters/x-scraper.ts", "src/index.ts", "src/app/x.ts", "src/domain/x.ts"]),
  ["src/adapters/x-scraper.ts", 'import "../app/run.ts";'],
  ["src/adapters/claude-translator.ts", 'import "../app/run.ts";'],
  ["src/adapters/claude-translator.ts", 'import "@the-convocation/twitter-scraper";'],
  ["src/adapters/claude-translator.ts", 'import { TIMELINE } from "./x-scraper.ts";\nvoid TIMELINE;'],
  ["src/adapters/lock-file.ts", 'import "../app/run.ts";'],
];

const allowed: [string, string][] = [
  ["src/adapters/x.ts", 'import "../app/ports.ts";'],
  ["src/app/x.ts", 'import "../domain/post.ts";'],
  ["src/adapters/x-scraper.ts", 'import "@the-convocation/twitter-scraper";'],
  ["src/index.ts", 'import "./app/run.ts";\nimport "./adapters/config.ts";'],
  ["src/index.ts", 'const m = await import("./adapters/x-scraper.ts");\nvoid m;'],
  ["src/adapters/sub/x.ts", 'import "../../app/ports.ts";'],
  ["src/adapters/slack-webhook.ts", 'import type { ScraperLike } from "./x-scraper.ts";\nexport type T = ScraperLike;'],
  // V5
  ...childProcess(["src/adapters/claude-translator.ts", "src/adapters/lock-file.ts"]),
  ["src/adapters/claude-translator.ts", 'import "../app/ports.ts";'],
];

test("V3: 決まりに反する読み込みは no-restricted-imports の違反になる", async () => {
  for (const [file, source] of violations) assert.equal(await restricted(file, source), true, `${file}: ${source}`);
});

test("V3: 決まりに合う読み込みは報告されない", async () => {
  for (const [file, source] of allowed) assert.equal(await restricted(file, source), false, `${file}: ${source}`);
});
