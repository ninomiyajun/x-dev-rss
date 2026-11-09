// モジュールのひな形（実装の最小の形）。受け取った値を、前後の空白を除いて返すだけである。
// 写して使うときは、ファイルの名前と関数の名前を、作るものに合わせて変える（templates/module/README.md）。
export function exampleLabel(value: string): string {
  return value.trim();
}
