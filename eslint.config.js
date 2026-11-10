import { builtinModules } from "node:module";
import eslint from "@eslint/js";
import tseslint from "typescript-eslint";

// 依存の向き（ARCHITECTURE.md の「依存の向き」）。試験のファイルは対象にしない。
// 層の禁止は、相対パスの深さによらず効くように、正規表現の形で書く。
const SCRAPER = "@the-convocation/twitter-scraper";
const NODE_MESSAGE = "この層は node の組み込みを使わない。";
const nodeBuiltinPaths = builtinModules.filter((m) => !m.startsWith("node:")).map((name) => ({ name, message: NODE_MESSAGE }));
const nodePattern = { regex: "^node:", message: NODE_MESSAGE };
const tests = ["**/*.test.ts"];

const restrict = (options) => ({ "no-restricted-imports": ["error", options] });

// 子プロセスを起動してよいのは、この 2 つのファイルだけ（計画の D11）。
// flat config では、同じファイルに当たる塊のうち後の塊の no-restricted-imports が前の塊の設定を置き換えるので、
// 塊ごとに既存の paths と並べて書く。
const CHILD_PROCESS_FILES = ["src/adapters/claude-translator.ts", "src/adapters/lock-file.ts"];
const CHILD_PROCESS_MESSAGE = "子プロセスを起動してよいのは src/adapters/claude-translator.ts と src/adapters/lock-file.ts だけ。";
const childProcessPaths = ["node:child_process", "child_process"].map((name) => ({ name, message: CHILD_PROCESS_MESSAGE }));

const adapterScraperPath = { name: SCRAPER, message: "取得のライブラリを読み込んでよいのは src/adapters/x-scraper.ts だけ。" };
const adapterAppPattern = { regex: "(^|/)app/(?!ports(\\.ts)?$)|(^|/)index(\\.ts)?$", message: "外との接続が読んでよい app のファイルは ports.ts だけ。" };
// ほかの接続は、取得のライブラリを含む x-scraper を値として読み込まない（型だけの読み込みはよい）。
const adapterNoScraperValue = {
  "@typescript-eslint/no-restricted-imports": [
    "error",
    {
      patterns: [
        {
          regex: "(^|/)x-scraper(\\.ts)?$",
          allowTypeImports: true,
          message: "取得のライブラリを含む x-scraper を読み込んでよいのは入口の動的な import だけ（型だけはよい）。",
        },
      ],
    },
  ],
};

export default tseslint.config(
  { ignores: ["node_modules/", "dist/", "scripts/harness/"] },
  eslint.configs.recommended,
  tseslint.configs.recommended,
  {
    files: ["src/domain/**/*.ts"],
    ignores: tests,
    rules: restrict({
      paths: [...nodeBuiltinPaths, { name: SCRAPER, message: "判定と文面は取得のライブラリを使わない。" }],
      patterns: [nodePattern, { regex: "(^|/)(app|adapters)(/|$)|(^|/)index(\\.ts)?$", message: "判定と文面は、ほかの層を使わない。" }],
    }),
  },
  {
    files: ["src/app/**/*.ts"],
    ignores: tests,
    rules: restrict({
      paths: [...nodeBuiltinPaths, { name: SCRAPER, message: "実行の流れは取得のライブラリを使わない。" }],
      patterns: [nodePattern, { regex: "(^|/)adapters(/|$)|(^|/)index(\\.ts)?$", message: "実行の流れは、判定と文面だけを使う。" }],
    }),
  },
  {
    files: ["src/adapters/**/*.ts"],
    ignores: [...tests, "src/adapters/x-scraper.ts", ...CHILD_PROCESS_FILES],
    rules: {
      ...restrict({ paths: [adapterScraperPath, ...childProcessPaths], patterns: [adapterAppPattern] }),
      ...adapterNoScraperValue,
    },
  },
  {
    // 子プロセスを起動してよい 2 つのファイル。外との接続の規則から、子プロセスの禁止だけを除く。
    files: CHILD_PROCESS_FILES,
    rules: {
      ...restrict({ paths: [adapterScraperPath], patterns: [adapterAppPattern] }),
      ...adapterNoScraperValue,
    },
  },
  {
    files: ["src/adapters/x-scraper.ts"],
    rules: restrict({ paths: childProcessPaths, patterns: [adapterAppPattern] }),
  },
  {
    // 入口は、取得のライブラリを含む x-scraper を静的に読み込まない（DEBUG を消した後に動的に読み込む。D13）。
    files: ["src/index.ts"],
    rules: restrict({
      paths: [{ name: SCRAPER, message: "入口は取得のライブラリを静的に読み込まない。" }, ...childProcessPaths],
      patterns: [{ regex: "(^|/)adapters/x-scraper(\\.ts)?$", message: "入口は x-scraper を静的に読み込まない（動的な import を使う）。" }],
    }),
  },
);
