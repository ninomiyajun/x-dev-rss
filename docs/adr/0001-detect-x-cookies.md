# 0001 X の Cookie を secretlint で検出する

## 背景

秘匿値の検査（secretlint）の既定の規則集は、Slack の Webhook の URL などは検出するが、X の Cookie は検出しない。
このプロジェクトは X の `auth_token`（40 桁の 16 進数）と `ct0`（32 桁以上の 16 進数）を扱うため、
誤ってコミットすると X のアカウントに成り代わられる。

## 判断

`.secretlintrc.json` の `@secretlint/secretlint-rule-pattern` に、名前付きで書かれた値を検出する規則を 4 つ足す。

- `X auth_token`: `X_AUTH_TOKEN`、`auth_token`、`authToken`、`auth-token` の後に区切り（引用符・空白・`:`・`=`）と 40 桁の 16 進数が続く形
- `X ct0`: `X_CT0` または `ct0` で始まる名前（`ct0Token` など）の後に区切りと 32 桁以上の 16 進数が続く形
- JSON の Cookie の書き出しの形（ブラウザの拡張や Playwright の storageState）: 同じ `{}` の中に `"name": "auth_token"` または `"name": "ct0"` と、32 桁以上の 16 進数の `"value"` がある形。`name` と `value` の順はどちらでもよい

TypeScript のコードで値を扱う名前は、上の形に合う名前（`authToken`・`ct0` など）にする。

## 検討した代わりの案

名前の無い 16 進数だけの文字列を検出する案は、コミットのハッシュなどを誤検出するため採らない。

## 結果

名前付きで書かれた X の Cookie の値は、secretlint が失敗にする。名前の無い 16 進数だけの値は検出されない。
`.gitignore` の `*.env` と `cookies*.json` が、秘匿値のファイル自体の誤コミットを防ぐ。
