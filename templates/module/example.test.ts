// モジュールのひな形（試験の最小の形）。node の組み込みの試験の道具（node:test）だけを使う。
// 写して使うときは、プロジェクトの試験の道具と書き方に合わせる（templates/module/README.md）。
import { test } from "node:test";
import assert from "node:assert/strict";
import { exampleLabel } from "./example.ts";

test("exampleLabel は前後の空白を除く", () => {
  assert.equal(exampleLabel("  見本  "), "見本");
});
