# x-dev-rss

X の公式アカウント @AnthropicAI のポストを取得し、まだ通知していない通常のポストを Slack の Incoming Webhook へ通知する
コマンドラインのアプリです。1 回動いて終わります。Mac の launchd から日次で起動する使い方を想定しています（launchd の設定は未作成）。

```
npm ci
npm run check
```

## 使い方

1. 手元の Claude Code（`claude` コマンド。既定のパスは `/opt/homebrew/bin/claude`）を、所有者の契約でログインした状態にします。
   ポストの本文の翻訳に使うもので、通常の実行はポストごとに `claude` を呼び、契約の使用量を使います。
   上限を超えた分を追加で支払う設定（extra usage）は有効にしません。
2. `~/.config/x-dev-rss/secrets.env`（権限 600。所有者以外にも読める権限だと止まります）に、次の 4 つの変数を `KEY=VALUE` の形で書きます。値はリポジトリに書きません。
   - `X_USERNAME`: 取得用の X のアカウントのユーザー名
   - `X_AUTH_TOKEN`、`X_CT0`: 取得用の X のアカウントの Cookie（`auth_token` と `ct0`）
   - `SLACK_WEBHOOK_URL`: Slack の Incoming Webhook の URL（`https://hooks.slack.com/` で始まるもの）
3. 対象のアカウントを `config/accounts.json` に書きます（既定は `{"accounts": ["AnthropicAI"]}`）。
4. `node src/index.ts` を実行します。

```
node src/index.ts [--config <パス>] [--state-dir <パス>] [--secrets <パス>] [--claude <絶対パス>] [--dry-run [--show-text]]
node src/index.ts --try-translate [--claude <絶対パス>] < 本文のファイル
```

- 通知済みの記録は `$XDG_STATE_HOME/x-dev-rss/notified.json`（環境変数が無いか、絶対パスでなければ `~/.local/state/x-dev-rss/notified.json`）に置きます。
  `--state-dir` で置き場を替えられます。
- `--dry-run` は、X から取得した結果を表示するだけで、Slack へ投稿せず、記録も読み書きしません。
- `--show-text` は `--dry-run` と一緒のときだけ使え、各ポストの行の次に、本文を 1 行の JSON の文字列の形で表示します。
- `--claude` は `claude` コマンドの絶対パスです（相対パスは使い方の 1 行を出して終了コード 2）。
- 通知するポストの本文は、日本語に訳して「（機械翻訳）」の印を付けて投稿します。日本語のポストと、訳す文の無いポストは、
  訳さずに原文のまま投稿します（印なし）。翻訳に失敗したポストは、原文のまま「（翻訳に失敗したため原文のまま）」の印を付けて
  投稿し、実行の出力に失敗した件数の行を出します。翻訳の失敗で終了コードは変わらず、通知も止まりません。
- `--try-translate` は、標準入力の本文（100,000 文字まで）だけを訳して表示します。X・Slack・秘匿値・通知済みの記録は使いません。
  1 行目に「訳した」「訳さなかった」「翻訳に失敗した」のどれかが出て、続けて本文、印、所要時間の行が出ます（終了コード 0）。
- 通知するのは通常のポストだけです（返信・リポスト・引用は通知せず、通知済みとして記録します）。1 回に候補にするのは、
  アカウントあたり新しいほうから 20 件の通常のポストです。記録がまだ無いアカウントでは、最も新しい 1 件だけを通知します。

設計は [ARCHITECTURE.md](ARCHITECTURE.md)、仕様は [docs/product-specs/x-post-to-slack.md](docs/product-specs/x-post-to-slack.md) と
[docs/product-specs/x-post-japanese.md](docs/product-specs/x-post-japanese.md) にあります。
