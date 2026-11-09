# x-dev-rss の規約

ハーネスの版: 1

この行は、このプロジェクトにハーネス（規約と検査の一式）を導入済みであることを示す印である。
`scripts/harness/check-docs.sh` が、この版で必須のファイルが揃っているかを確かめる。印の書式（「ハーネスの版: 」に
整数を続けた 1 行）は、ハーネスの規約が定めたものに合わせている。版の数は、必須のファイルが増えるときに上げ、
同じ変更で設定のファイル `scripts/harness/harness.conf` に、その版の `required.<版>=<パス>` の行を足す。
`scripts/harness/` の検査の本体（冒頭に `harness-copy` の行があるファイル）は規約の正本の写しなので、手で変えない。
このプロジェクトだけの検査は `scripts/harness/checks.d/` に足す（決まりは同じ置き場の `README.md`）。

## このプロジェクト

X の @AnthropicAI のポストを 1 日 1 回取得し、Slack の決まった 1 つのチャンネルへ通知するコマンドラインのアプリ。
サーバーではなく、1 回動いて終わる。使うのはリポジトリの所有者 1 人で、所有者の Mac で日次に自動で実行し
（launchd で起動する予定。設定はまだ作っていない）、結果を Slack で読む。リポジトリは GitHub で公開している。

## コードから推測できない決定

- X のポストの取得には `@the-convocation/twitter-scraper` の 0.22.3 を使い、取得用の X のアカウントの Cookie（`auth_token` と
  `ct0`）でログインする。この版は、リポジトリの外での試験でポストを取得できた版で、依存にはまだ入れていない。X の公式 API は使わない。
- Slack への投稿は、Incoming Webhook の URL へ送る。
- 秘匿値は、リポジトリの外の `~/.config/x-dev-rss/secrets.env`（権限 600）に置く。変数は `X_USERNAME`、`X_AUTH_TOKEN`、
  `X_CT0`、`SLACK_WEBHOOK_URL` の 4 つで、値をリポジトリ・ログ・出力に出さない。エージェントは `secrets.env` を読まず、
  値を表示しない（変数の有無を確かめるときも値を出さない）。
- 費用は無料に限る（有料のサービスや API を使わない）。
- 取得に使う X のアカウントが凍結されても、別のアカウントへ乗り換えない（所有者が決めたこと）。代わりに、Apify の無料プランなど、無料で使える取得のサービスへの切り替えを所有者に提案する。
- 次の点はまだ決めていない。既に通知したポストの記録の置き場、通知の文面、取得の件数、失敗したときの再試行、層の分け方。
  最初の機能（X の取得と Slack への投稿）の仕様と設計で決める。

## 秘匿値と個人情報（必須）

- 秘匿値（API の鍵、トークン、Cookie、パスワード）をリポジトリのファイルに書かない。
- `.env` で始まるファイルは `.gitignore` で除外する。例外は、変数の名前だけを書く `.env.example` だけで、値は書かない。
- コミットするファイルに個人情報（アカウント名、姓名、メールアドレス）とホームの絶対パスを書かない。パスは `~/...` か
  プレースホルダーで書く。
- push の前に、`git fetch --prune origin` の後で `bash scripts/harness/check-secrets.sh --commits` を通す。手元のすべてのブランチと
  タグから辿れて、push 先のリモートの追跡ブランチから辿れないコミット（初回の push ではすべてのコミット）に記録された中身と
  コミットメッセージ、手元のすべての注釈付きのタグの注釈を調べる。push 先が `origin` でなければ `--remote <名前>` を足す。
  作業ツリーだけを調べる `bash scripts/harness/check-secrets.sh` では、途中のコミットに入れて後で消した値を見落とすためである。
- 秘匿値の検査を弱めない。`.secretlintignore` のファイルと secretlint の無効化のコメントは、検査が失敗にする。
  誤検出は `.secretlintrc.json` の設定で直し、理由を設計判断の記録に書く。

## 検査のコマンド

| 何を確かめるか | コマンド |
|---|---|
| 全部（CI と同じ順） | `npm run check` |
| lint | `npm run lint` |
| 型 | `npm run typecheck` |
| 試験 | `npm run test` |
| 文書（必須のファイル、CLAUDE.md、地図、リンク、目録、行数、ARCHITECTURE.md に書いたパス、計画の必須の節、受け入れ確認の記録、製品の仕様の目録と状態、古い計画、検査の由来の記録、写しの中身） | `bash scripts/harness/check-docs.sh` |
| 文書の検査の試験（`check-docs.sh` の検査と設定、追加の検査の口の試験） | `bash scripts/harness/check-docs.test.sh` |
| 早期通知と定期の走査の試験 | `bash scripts/harness/notify.test.sh` と `bash scripts/harness/drift-scan.test.sh` |
| 定期の走査の段の読み取りの試験 | `bash scripts/harness/stack-adapter.test.sh` |
| 秘匿値（作業ツリーの、コミットする全ファイル） | `bash scripts/harness/check-secrets.sh` |
| 秘匿値（push する範囲の各コミットの中身） | `bash scripts/harness/check-secrets.sh --commits` |

リンクの検査が見るのは、インラインのリンクと画像（角括弧の文字の直後に、丸括弧で囲んだ先を続ける形）で、先に空白も
`)` も含まないものだけである。参照形式のリンク、山括弧で囲んだ先、タイトル付きの先、自動リンク、HTML の a 要素は検査しないので、
文書の中のリンクはインラインの形で書く。

## 文書の地図

| 種類 | パス | 読む条件 |
|---|---|---|
| 設計の正本（層、依存の向き、不変条件） | `ARCHITECTURE.md` | コードを変える前 |
| 設計判断の記録 | `docs/adr/README.md` | 設計を変える前、過去の判断の理由を知りたいとき |
| 製品の前提 | `docs/PRODUCT_SENSE.md` | 新しい機能や画面を考えるとき |
| 製品の仕様（書式と目録） | `docs/product-specs/README.md` | 新しい機能や画面の仕様を書くとき、仕様を引く計画を書くとき・確かめるとき |
| 計画の書式 | `docs/PLANS.md` | 計画を書くとき、計画を読むとき |
| アプリの起動の手順 | `.claude/skills/run-x-dev-rss/SKILL.md` | アプリを起動して画面を確かめるとき（受け入れ確認を含む） |
| 進行中の計画 | `docs/exec-plans/active/` | 作業を再開するとき |
| 完了した計画 | `docs/exec-plans/completed/` | 過去の作業の経緯を知りたいとき |
| 技術的負債の一覧 | `docs/exec-plans/tech-debt-tracker.md` | 作業の範囲外の問題を見つけたとき、文書を点検するとき |
| 検査の由来の記録 | `docs/harness-log.md` | 指摘を検査にするとき、検査の理由を知りたいとき |
| 品質目標 | `docs/QUALITY_SCORE.md` | 設計の品質を判断するとき |
| 検査 | `scripts/harness/` | 検査を足すか変えるとき（本体は写しなので手で変えない。専用の検査は同じ置き場の checks.d に置く） |
| 検査（CI の設定） | `.github/workflows/` | CI の検査を足すか変えるとき |
| モジュールのひな形 | `templates/module/` | 新しいモジュールを足すとき |
| 検査（定期の走査） | `.github/workflows/drift-scan.yml` | 定期の走査（`scripts/harness/drift-scan.sh`）を変えるとき。段の読み取りは `scripts/harness/stack-adapter.sh` |

## 落とし穴

- Claude Code は、`CLAUDE.md` があるとこのファイルを自分からは読まない。そのため `CLAUDE.md` に `@AGENTS.md` だけの行を
  置いている。この行を消さず、指示はこのファイルに書く（`bash scripts/harness/check-docs.sh` が、`@AGENTS.md` だけの行があることを確かめる）。
