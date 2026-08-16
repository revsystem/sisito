# テスト基盤の整備と etc 二重計上の修正 設計仕様

日時: 2026-08-11
深度: standard
対象 Issue: [#39](https://github.com/revsystem/sisito/issues/39)（テスト基盤）、[#38](https://github.com/revsystem/sisito/issues/38)（etc 二重計上）

## 目的・コンセプト

自動テストが一切機能していない状態を解消し、その基盤の上で `etc` 二重計上バグを修正する。

#36 の実装では、日付範囲フィルタという明確なロジック変更に対して自動テストを 1 本も追加できず、検証は Pi 上での実地確認と直接 SQL の突き合わせに全面依存した。手作業のコストが高いだけでなく、`BounceMail.within_period` の境界条件（`to` 当日を含む）のような一度確認した性質が、次の変更で壊れても誰も気づけない。

#38 はチャートの表示数値が変わる修正であり、まさに回帰テストが欲しい種類の変更である。したがって #39 を先に片付け、#38 はその基盤の上でテストと同時に実装する。

## 想定利用者と利用シーン

利用者はリポジトリ所有者本人。ローカル（WSL2）は編集専用で MySQL が無く gem も入れない方針のため、テストを日常的に走らせる場所は GitHub Actions になる。PR を出したときに自動で走り、壊れていれば PR 上で分かる、という使い方を想定する。

最重要の制約として、Raspberry Pi は唯一の実運用ホストであり、そこにテスト用データベースを置かない。Rails のテストは対象データベースを破棄・再生成するため、`sisito_development` と同居させる価値よりリスクが大きい。

## スコープ

含めること。GitHub Actions へのテストジョブ追加（MySQL 8.0 サービスコンテナ）、`config/environments/test.rb` の Rails 7.2 準拠への修正、stale な `status_controller_test.rb` の修正、`bounce_mails` の fixtures 作成、`BounceMail.within_period` の境界条件テスト、`etc` 二重計上の修正（6 箇所）とそのテスト。

含めないこと。網羅的なテストの追加。既存の全コントローラ・全ビューを covered にすることは目指さない。カバレッジ計測ツール（simplecov 等）の導入も行わない。`shorten_stats` や OAuth 経路のテストも今回は書かない。

線引きの根拠は、基盤が無い状態から一気に網羅を目指すと、fixtures の設計だけで作業が発散するためである。「CI で走る」「意味のあるテストが数本ある」「#38 が守られる」の 3 点を満たすところまでを今回の到達点とし、以降は変更のたびに足していく。

## アーキテクチャ設計

テストの実行環境は GitHub Actions のみとする。ワークフローは既存の `bundler-audit.yml` と別ファイル（`.github/workflows/test.yml`）に分ける。目的が違い、トリガも異なる（bundler-audit は weekly cron を持つがテストには不要）ためである。

データベースは `services:` の MySQL 8.0 コンテナを使い、`config/database.yml` の test ブロックが指す `sisito_test` に `db:schema:load` でスキーマを流す。migration を順に当てるのではなく `schema.rb` を読ませる方式にするのは、`20250705000002` が MySQL では部分インデックスにならないなど、migration 履歴に環境依存の癖があるためだけではない。より直接的な理由は `db/migrate/20170128144003_example_data.rb` の存在で、これは `Date.today - rand(14).days` で約 700 行の `bounce_mails` と 3 行の `whitelist_mails` を投入する。境界条件テストが要求する「固定の日付・件数」と非決定的な乱数データは両立しない。`db:migrate` で履歴を素直に辿るとこのマイグレーションを踏んでしまうため、CI は `db:create` の後 `db:schema:load` に固定し、migration 履歴を辿らせない。`schema.rb` にはデータが無く、CI が検証すべきはそちらになる。

テストの種類はモデルテストとコントローラ（統合）テストの 2 層に留める。システムテスト（ブラウザ駆動）は導入しない。C3.js のチャートはサーバー側が生成した JS リテラルをそのまま埋め込む構造なので、`etc` の計算のようなロジックはレスポンス本文の文字列として検証できる。ヘッドレスブラウザを持ち込む必要がない。

## 技術選定と根拠

テストフレームワークは Rails 標準の Minitest をそのまま使う。`test/` ディレクトリと `test_helper.rb` が既にあり、RSpec への移行は本タスクの目的ではない。

fixtures は Rails 標準の YAML fixtures を使う。FactoryBot は依存が増え、`bounce_mails` のように全カラムが `NOT NULL` のテーブルではデフォルト値の定義場所が変わるだけで利点が薄い。

MySQL は 8.0 系をサービスコンテナで使う。Pi の本番相当環境と揃えるためで、SQLite への差し替えはしない。`sql_mode: TRADITIONAL` の挙動や `COUNT(DISTINCT ...)` の扱いが変わると、テストが通っても実環境で壊れる余地が生まれる。

## データ設計

スキーマ変更なし。

fixtures は `bounce_mails` のみを用意する。`bounce_mails` は `id` を除く 24 カラムすべてが `NOT NULL`（`digest` のみ `default: ""` を持つ）で、共通のデフォルトを YAML の ERB か fixture の共通定義でまとめ、テストごとに意味のあるカラム（`timestamp`、`reason`、`destination`、`recipient`、`addresser`、`addresseralias`、`senderdomain`）だけを上書きする形にする。

共通デフォルトを YAML アンカー（`defaults: &defaults` をトップレベルキーとして書く形）で作ると、`defaults` という名前自体が 1 件の `bounce_mails` 行として fixtures に登録されてしまう。全カラム NOT NULL のテーブルではこの行にも有効な値が要求され、境界条件テストの件数・`within_period` の集計件数に 1 行余分に乗る。実装時は ERB でハッシュを組み立てて各エントリに展開するか、既存の実レコード 1 件目をアンカーにするなど、トップレベルにダミーの fixture 行を作らない書き方にする。

`whitelist_mails` の fixtures は用意しない。今回追加するテスト（`within_period` の境界条件、`etc` の合計一致、`status` のスモーク、`StatsController#index` の統合テスト）はいずれも `whitelist_mails` を参照しないためである。`whitelist_mails.digest` は `NOT NULL` かつデフォルト値が無く、用意する場合は明示的に値が要る点は今後の参考として記録しておく。

fixtures の中身は、境界条件と集計ロジックを検証できる最小構成にする。日付境界の検証には「範囲の開始日 00:00:00」「終了日 23:59:59」「終了日翌日 00:00:00」の 3 点が要る。`etc` の検証には、個別表示件数 N を超える件数の destination が必要になる。`StatsController#index` の統合テストに使う fixtures の日付は固定値とし、テストのリクエストでも `params[:from]` / `params[:to]` を同じ固定値で明示的に渡す。`index` のデフォルト期間（`params` が無ければ `to = Date.today`）に乗せると、`Date.today` が動くたびに fixtures の日付が既定表示の範囲から外れ、テストが非決定的になる。

## 要件ごとの実装方針

`config/environments/test.rb` の `config.action_dispatch.show_exceptions = false` を `:none` に改める。actionpack 7.2.3.2 の `ExceptionWrapper#show?` は `:none` / `:rescuable` / else の case 判定であり、boolean の `false` は else に落ちて「例外を表示する」と解釈される。現状のままだと統合テストで例外が送出されず 500 が描画されるため、テストの失敗理由が分かりにくくなる。

`status_controller_test.rb` はクラス名を `StatusControllerTest` に直し、`monitor_index_url` を実在する `status_url` に変える。`StatusController#index` の集計窓は `Time.now - interval` を都度計算するため、fixtures に入れた固定の過去日時は集計対象から外れる。この修正はルーティングの是正と HTTP 200 のスモーク確認に留め、JSON の中身（件数）は断言しない。中身を検証するなら `travel_to` で時刻を固定するか、集計窓に入る時刻を都度計算して fixtures を作る必要があり、これは今回のスコープ外とする。

`etc` の修正は個別表示件数を 3 件に揃える。個別スライスは上位 3 件、`etc` は残り全件の合計とすることで、両者の合計が実件数と一致する。この定型は 6 箇所に重複しており、`_bounced_by_type` だけ入力が Hash ではなくソート済み Array である点を吸収する必要がある。ヘルパーへの切り出しは残決定事項とする。

ヘルパーの契約として、残りが空の場合は `etc` 行を追加しないことを明記する。現行コードは `values.slice(3..-1).try(:sum)` が返す `nil` を `present?` で弾いており、対象が 3 件未満なら `etc` が出ない。ただし対象がちょうど 3 件のときは `slice(3..-1)` が `nil` ではなく空配列 `[]` を返し、`[].try(:sum)` は `0`、`0.present?` は `true` となるため、現行コードは既にこのケースで `etc: 0` を出している（#36 の Pi 検証時に実データで観測: `bounced_by_mailboxfull` が `icloud.com: 4, gmail.com: 2, softbank.ne.jp: 1` の 3 件に対し `etc: 0` を含んでいた）。したがって「残りが空なら `etc` を出さない」は新実装で初めて必要になる配慮ではなく、既存コードが `nil` 経由でしか担保できていなかった契約を、境界（ちょうど 3 件）まで含めて明示的に担保し直す修正になる。実装は `slice(top..-1)`（要素数が `top` 未満だと `nil` を返し得る）ではなく `drop(top)`（要素数によらず必ず `Array` を返す。0 件残りなら `[]`）を使い、`present?`（`0` を通す）ではなく `.empty?` で残りの有無を判定する。`slice` を残したまま `present?` を `empty?` に変えるだけでは、0〜2 件残りのケースで `nil.empty?` が `NoMethodError` になるため、切り出し方法と判定方法は必ず対で変える。

もう一点、ヘルパーは受け取ったコレクションを破壊しないことも契約に含める。`Array#to_a` は自身が `Array` のとき同一オブジェクトを返すため、`_bounced_by_type` から渡されるソート済み配列に対して `to_a` を呼んでも新しい配列は作られない。その後に `push` 等の破壊的メソッドを使うと呼び出し元の配列まで変更されるため、ヘルパー内部では複製してから操作する。

## 性能・品質・セキュリティ上の前提

CI の実行時間が増える。MySQL コンテナの起動、`bundle install`（キャッシュあり）、`db:schema:load`、テスト実行で数分を見込む。PR ごとに走るため、テストが遅くなるとレビューの待ち時間になる。今回追加するテストは数本なので当面は問題にならない。

`config/secrets.yml` に test 用の `secret_key_base` が含まれており、これは既にリポジトリに追跡されている。CI で新たに秘密情報を渡す必要はない。MySQL サービスコンテナのパスワードは `config/database.yml` の test ブロックが `root` / パスワード無しを指しているため、コンテナ側も `MYSQL_ALLOW_EMPTY_PASSWORD` で揃える。CI 専用の使い捨て環境であり、秘密情報の漏洩経路にはならない。

## リスクと対策

最大のリスクは、CI を追加した結果テストが赤いまま放置されることである。基盤だけ作ってテストが 1 本も意味を持たないと、次に誰かが赤を見ても直す動機が湧かない。対策として、今回追加するテストは「壊れたら本当に困るもの」に絞る。具体的には `within_period` の境界条件と `etc` の合計一致の 2 点で、どちらも過去に実際に問題があった箇所である。

このリスクは、テストの中身だけでは防げない。今テストが機能していない直接の原因は「誰も走らせていない」ことであり、CI ジョブ自体が最初から赤いままマージされ続ければ同じ状態の再現になる。対策として、実装順序を「`test.yml` が緑になることを確認してから #38 の本番コード（`etc` 修正）に着手する」に固定する。MySQL サービスコンテナには healthcheck を付け、DB 未起動での接続失敗とテスト自体の失敗を区別できるようにする。Ruby のバージョン取得は既存の `bundler-audit.yml` と同じ `ruby/setup-ruby@v1`（`ruby-version` 未指定）を使う。これは実際に `mise.toml` の `ruby = "3.4.9"` を読んで 3.4.9 をインストールすることを、直近の `bundler-audit` の実行ログ（`Using 3.4.9 as input from file mise.toml`）で確認済みであり、リポジトリに `.ruby-version` が無くても追加設定なしで動く。統合テストは `application.html.erb` 経由でアセット（Sprockets + dartsass）を要求するため、`assets:precompile` またはテスト環境でのアセットコンパイルが CI 上で通ることも実装時に確認する。

次に、fixtures の設計が実データとかけ離れるリスクがある。`bounce_mails` は 137 万行の実データを持つが、fixtures は数件になる。集計ロジックの検証には十分だが、性能特性は再現できない。性能は引き続き Pi での実測に依存する、と割り切る。

三点目として、#38 の修正はチャートの表示数値を変える。これまで見ていた合計が減るため、利用者から見ると「数字が変わった」ように映る。Issue #38 に影響として記載済みだが、リリース時に改めて明示する。

## 残決定事項（判断ポイント）

### 論点1: `etc` の定型をヘルパーへ切り出すか

同じ `slice` / `push` / `select` / `inspect` の定型が 6 箇所に重複している。`_bounced_by_type` だけ入力がソート済み Array で、他の 5 箇所は Hash である。

- A. 各ビューで `slice(0, 3)` / `slice(3..-1)` に直すだけに留める — 利点: 差分が最小で、修正箇所とテストの対応が追いやすい / 欠点: 重複が 6 箇所のまま残り、次に N を変えるとき再び 6 箇所を直すことになる
- B. `StatsHelper` に `chart_columns(collection, top: 3)` を追加し、6 箇所すべてを置き換える。Hash と Array の差は `to_a` で吸収する — 利点: N が単一の情報源になり、テストもヘルパー 1 本に集約できる / 欠点: ビューの見た目が大きく変わり、diff レビューの負担が増える
- C. その他（自由記述）

推奨: B。今回まさに「6 箇所を直す」作業をしており、同じことを次も繰り返す構造を残す理由が薄い。ヘルパー単体テストで `etc` の合計一致を直接検証でき、ビュー側のテストは 1 本の代表確認で足りる。

[Answer]: B

### 論点2: CI のトリガ範囲

既存の `bundler-audit.yml` は push to master / pull_request / weekly cron の 3 つで走る。

- A. push to master と pull_request の 2 つ — 利点: PR で結果が見え、master へ入った後も確認される。cron が無いぶん無駄が少ない / 欠点: 依存の更新で壊れるケースは PR が出るまで気づけない
- B. bundler-audit と同じ 3 つ（weekly cron を含む）— 利点: 外部要因の破損に気づける / 欠点: テストは自リポジトリのコードにしか依存しないため、cron の実行はほぼ常に同じ結果になる
- C. pull_request のみ — 利点: 最小 / 欠点: master への直接 push が検証されない
- D. その他（自由記述）

推奨: A。テストは外部の advisory データベースを参照する bundler-audit とは性質が違い、定期実行の価値が低い。

[Answer]: A

### 論点3: 今回書くテストの範囲

基盤を作った上で、どこまでテストを書くか。

- A. `within_period` の境界条件（モデル）と `etc` の合計一致（ヘルパーまたはビュー）、`status_controller_test.rb` の修正の 3 点に絞る — 利点: すべて「過去に実際に問題があった箇所」で、費用対効果が高い / 欠点: `StatsController#index` 全体の描画は covered にならない
- B. A に加えて `StatsController#index` の統合テストを足し、8 集計ブロックすべてが期間フィルタを反映すること・期間ラベルが出ることを固定の `from`/`to` を指定したリクエストで確認し、別途データの無い固定期間へのリクエストで `No data in this period.` が出ることを確認する — 利点: #36 で手作業検証した内容の主要部分が自動化される / 欠点: fixtures の設計がやや重くなり、リクエストが最低 2 本になる
- C. B に加えて `BounceMailsController` / `WhitelistMailsController` など他コントローラにも広げる — 利点: カバレッジが上がる / 欠点: 本タスクが発散する
- D. その他（自由記述）

推奨: B。#36 の検証コストがそのまま次回も掛かる状態を避けたい。fixtures は結局 `bounce_mails` を数件用意する話であり、A から B への増分は大きくない。

[Answer]: B
