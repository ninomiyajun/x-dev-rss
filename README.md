# x-dev-rss

X の公式アカウント @AnthropicAI のポストを取得し、まだ通知していない通常のポストを Slack の Incoming Webhook へ通知する
コマンドラインのアプリです。1 回動いて終わります。Mac の launchd から日次で起動する使い方を想定しています（launchd の設定は未作成）。

```
npm ci
npm run check
```

## 使い方

1. `~/.config/x-dev-rss/secrets.env`（権限 600。所有者以外にも読める権限だと止まります）に、次の 4 つの変数を `KEY=VALUE` の形で書きます。値はリポジトリに書きません。
   - `X_USERNAME`: 取得用の X のアカウントのユーザー名
   - `X_AUTH_TOKEN`、`X_CT0`: 取得用の X のアカウントの Cookie（`auth_token` と `ct0`）
   - `SLACK_WEBHOOK_URL`: Slack の Incoming Webhook の URL（`https://hooks.slack.com/` で始まるもの）
2. 対象のアカウントを `config/accounts.json` に書きます（既定は `{"accounts": ["AnthropicAI"]}`）。
3. `node src/index.ts` を実行します。

```
node src/index.ts [--config <パス>] [--state-dir <パス>] [--secrets <パス>] [--dry-run]
```

- 通知済みの記録は `$XDG_STATE_HOME/x-dev-rss/notified.json`（環境変数が無いか、絶対パスでなければ `~/.local/state/x-dev-rss/notified.json`）に置きます。
  `--state-dir` で置き場を替えられます。
- `--dry-run` は、X から取得した結果を表示するだけで、Slack へ投稿せず、記録も読み書きしません。
- 通知するのは通常のポストだけです（返信・リポスト・引用は通知せず、通知済みとして記録します）。1 回に候補にするのは、
  アカウントあたり新しいほうから 20 件の通常のポストです。記録がまだ無いアカウントでは、最も新しい 1 件だけを通知します。

設計は [ARCHITECTURE.md](ARCHITECTURE.md)、仕様は [docs/product-specs/x-post-to-slack.md](docs/product-specs/x-post-to-slack.md) にあります。
