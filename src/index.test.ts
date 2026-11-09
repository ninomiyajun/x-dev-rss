import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

test("起動すると使い方を 1 行出して終わる", () => {
  const entry = fileURLToPath(new URL("./index.ts", import.meta.url));
  const out = execFileSync(process.execPath, [entry], { encoding: "utf8" });
  assert.equal(out, "使い方: node src/index.ts\n");
});
