# テスト基盤の整備と etc 二重計上の修正 実装計画

日時: 2026-08-11
深度: standard
関連調査: [.claude/docs/research/2026-08-11-test-harness-and-etc-slice-fix-research.md](../research/2026-08-11-test-harness-and-etc-slice-fix-research.md)
設計仕様: [.claude/docs/specs/2026-08-11-test-harness-and-etc-slice-fix-spec.md](../specs/2026-08-11-test-harness-and-etc-slice-fix-spec.md)

## 概要

自動テストが機能していない状態（#39）を解消し、その基盤の上で `etc` 二重計上バグ（#38）を修正する。GitHub Actions に MySQL 8.0 サービスコンテナ付きのテストジョブを追加し、`config/environments/test.rb` を Rails 7.2 準拠に直し、`bounce_mails` の fixtures と境界条件テストを新設したうえで、`StatsHelper#chart_columns` に `etc` の集計ロジックを1箇所に集約して6箇所のビューを置き換える。

## アプローチ

spec の残決定事項（論点1: B＝ヘルパー切り出し、論点2: A＝push to master + pull_request、論点3: B＝統合テストを追加）を前提とする。

`chart_columns(collection, top: 3)` の実装は、research.md で確認した2つの罠を避ける設計にする。切り出しは `slice(top..-1)` ではなく `drop(top)` を使い（要素数によらず必ず `Array` を返す）、`etc` を出すかどうかの判定は `present?` ではなく `.empty?` で行う。残りの合計は `pairs.drop(top).sum` ではなく `pairs.drop(top).sum {|_, v| v }`（ペア配列のまま `sum` を呼ぶと `TypeError` になるため）。これにより、現行コードが `nil` 経由でしか担保できていなかった「対象が少ないときは `etc` を出さない」という契約を、境界（ちょうど3件）まで含めて明示的に担保する。

CI は既存の `bundler-audit.yml` と同じ `ruby/setup-ruby@v1`（`mise.toml` から Ruby 3.4.9 を自動検出することを確認済み）を使い、別ワークフローファイルとして追加する。データベースは `db:schema:load` に固定し `db:migrate` は使わない。`db/migrate/20170128144003_example_data.rb` が `Date.today - rand(14).days` で非決定的なデータを投入するためで、`db:schema:load` はこのマイグレーションの内容を実行せず、バージョン番号だけを「migrated 済み」として記録するため `maintain_test_schema!` の `PendingMigrationError` も起きない(research.md で activerecord 7.2.3.2 のソースを読んで確認済み)。

## 変更内容

### 変更1: test 環境の show_exceptions 修正

対象: `config/environments/test.rb`

```ruby
# 変更前
  config.action_dispatch.show_exceptions = false

# 変更後
  config.action_dispatch.show_exceptions = :none
```

`false` は actionpack 7.2.3.2 の `ExceptionWrapper#show?` の case 式で `else` に落ち、「例外を表示する」（re-raise しない）と解釈される。`:none` にすることで、テスト内の例外が Minitest にそのまま伝播する。

### 変更2: GitHub Actions テストジョブの追加

対象: `.github/workflows/test.yml`（新規）

```yaml
name: test

on:
  push:
    branches: [master]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    services:
      mysql:
        image: mysql:8.0
        env:
          MYSQL_ALLOW_EMPTY_PASSWORD: yes
          MYSQL_DATABASE: sisito_test
        ports:
          - 3306:3306
        options: >-
          --health-cmd="mysqladmin ping --silent"
          --health-interval=10s
          --health-timeout=5s
          --health-retries=10
    env:
      RAILS_ENV: test
      DISABLE_SPRING: 1
      DATABASE_URL: mysql2://root@127.0.0.1:3306/sisito_test
      TZ: UTC
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      - name: Prepare test database
        run: bin/rails db:create db:schema:load
      - name: Run tests
        run: bin/rails test
```

`DATABASE_URL` で `127.0.0.1` を明示するのは、`config/database.yml` の test ブロックが `host: localhost` を指しており、MySQL クライアントライブラリ（mysql2 gem が使う libmysqlclient）は慣習的に `localhost` を Unix ソケット接続の指示として扱うためである。GitHub Actions のサービスコンテナは TCP でしか到達できないため、`localhost` のままだと接続に失敗する可能性がある。`DATABASE_URL` を設定すると Rails はその環境の接続情報を `database.yml` より優先して使うため、コミット済みの `database.yml` 自体は変更しない。この振る舞いは CI を初めて走らせたときに実地で確認する。

`TZ: UTC` は fixtures の日時文字列（変更3）を意図どおりの時刻として保存させるための必須設定であり、任意の防御策ではない。research.md で実測したとおり、fixtures YAML のオフセット無し日時文字列は、それをパースするプロセスの `TZ` によって実際に格納される時刻が変わる（`config.active_record.default_timezone = :local` のため、Psych がプロセスのローカルタイムゾーンで解釈した `Time` がそのまま `getlocal` 経由で SQL に書き込まれる）。GitHub Actions の `ubuntu-latest` は既定で UTC だが、これはランナーイメージの既定値であり実装が依存してよい契約ではないため、明示的に `TZ: UTC` を宣言し、fixtures の日時文字列を UTC 前提の値として書く。

`DISABLE_SPRING=1` は、`bin/rails` が `bin/spring` を経由する構成になっており(`config/spring.rb` あり)、CI の使い捨てコンテナで Spring デーモンを起動させないための保険。Pi で Spring がキャッシュを持ち越して混乱した経緯(CLAUDE.md の Gotcha 9)があるため、CI では最初から無効化する。

`--health-cmd` を設定すると GitHub Actions がサービスコンテナのヘルスチェック成功を待ってからジョブのステップを開始するため、明示的な待機ループは不要。

トリガーは push to master と pull_request の2つ（spec 論点2の回答 A）。bundler-audit にある weekly cron は含めない。

### 変更3: `BounceMail.within_period` の境界条件テスト

対象: `test/fixtures/bounce_mails.yml`（新規）

共通デフォルトは Rails fixtures 組み込みの `DEFAULTS` キー（大文字。`ActiveRecord::FixtureSet` が無条件に無視する予約名）をアンカーにする。トップレベルに自作のダミーキーを作らない(research.md で確認した Rails 標準の回避策)。

```yaml
DEFAULTS: &DEFAULTS
  lhost: mail.example.com
  rhost: mail.test1.example.com
  alias: default@test1.example.com
  listid: ""
  reason: userunknown
  action: failed
  subject: hello
  messageid: default@xxx.mail
  smtpagent: MTA::Postfix
  hardbounce: false
  smtpcommand: RCPT
  destination: test1.example.com
  senderdomain: example.com
  feedbacktype: ""
  diagnosticcode: "550 no such user"
  deliverystatus: "5.0.0"
  timezoneoffset: "+0900"
  addresser: no-reply@example.com
  addresseralias: ""
  digest: ""

boundary_start:
  <<: *DEFAULTS
  timestamp: 2026-08-01 00:00:00
  recipient: boundary_start@test1.example.com

day_before_start:
  <<: *DEFAULTS
  timestamp: 2026-07-31 23:59:59
  destination: excluded-before.example.com
  recipient: day_before_start@excluded-before.example.com

boundary_end:
  <<: *DEFAULTS
  timestamp: 2026-08-02 23:59:59
  reason: filtered
  destination: test2.example.com
  recipient: boundary_end@test2.example.com

boundary_next_day:
  <<: *DEFAULTS
  timestamp: 2026-08-03 00:00:00
  destination: excluded-after.example.com
  recipient: boundary_next_day@excluded-after.example.com
```

固定の過去日付（2026-08-01/02）を使う。`Date.today` に依存する値は一切含めない。`boundary_start` は `from` の00:00:00（下限を含む）、`boundary_end` は `to` の23:59:59(上限を含む)、`day_before_start` と `boundary_next_day` はそれぞれ範囲の外側1秒・1マイクロ秒相当の外側にあり、除外されることを確認する。`boundary_start` と `boundary_end` は destination・reason を変えており、変更5の統合テストでも「範囲内が反映されること」の確認に流用する。

これらの日時文字列はオフセット無しの YAML 日時として書いており、変更2 の CI ワークフローで `TZ: UTC` を設定していることが前提になる(research.md「fixtures の日時は CI ランナーの TZ に依存して意味が変わる」を参照)。`TZ` を設定しない、または UTC 以外にすると、境界条件テストが意図と異なる時刻を検証することになる。

対象: `test/models/bounce_mail_test.rb`（新規）

```ruby
require "test_helper"

class BounceMailTest < ActiveSupport::TestCase
  test "within_period includes the start of the range at 00:00:00" do
    result = BounceMail.within_period(Date.parse("2026-08-01"), Date.parse("2026-08-02"))
    assert_includes result, bounce_mails(:boundary_start)
  end

  test "within_period includes the end of the range at 23:59:59" do
    result = BounceMail.within_period(Date.parse("2026-08-01"), Date.parse("2026-08-02"))
    assert_includes result, bounce_mails(:boundary_end)
  end

  test "within_period excludes the day before the range" do
    result = BounceMail.within_period(Date.parse("2026-08-01"), Date.parse("2026-08-02"))
    assert_not_includes result, bounce_mails(:day_before_start)
  end

  test "within_period excludes the day after the range" do
    result = BounceMail.within_period(Date.parse("2026-08-01"), Date.parse("2026-08-02"))
    assert_not_includes result, bounce_mails(:boundary_next_day)
  end
end
```

### 変更4: `StatsHelper#chart_columns` の追加

対象: `app/helpers/stats_helper.rb`

```ruby
module StatsHelper
  # セクション見出しに添える集計期間の表記。
  # Recently Bounced は直下のフォームに from/to が出ているため対象外。
  def stats_period_label(from, to)
    "#{from.strftime('%Y-%m-%d')} 〜 #{to.strftime('%Y-%m-%d')}"
  end

  # 上位 top 件を個別系列、残り全件の合計を 'etc' として返す。
  # 残りが空なら 'etc' 系列は追加しない（0 件の etc を出さない）。
  # collection は Hash（key => count）または [key, count] のソート済み配列のどちらでもよい。
  # 呼び出し元のコレクションは変更しない（drop/first はいずれも非破壊）。
  def chart_columns(collection, top: 3)
    pairs = collection.to_a
    columns = pairs.first(top)
    remainder = pairs.drop(top)
    remainder.empty? ? columns : columns + [['etc', remainder.sum {|_, v| v }]]
  end
end
```

対象: `test/helpers/stats_helper_test.rb`（新規）

```ruby
require "test_helper"

class StatsHelperTest < ActionView::TestCase
  test "returns individual slices without an etc entry when nothing remains" do
    assert_equal [["a", 5], ["b", 3], ["c", 1]], chart_columns({"a" => 5, "b" => 3, "c" => 1})
  end

  test "adds an etc entry summing everything past top" do
    columns = chart_columns({"a" => 5, "b" => 3, "c" => 1, "d" => 1})
    assert_equal [["a", 5], ["b", 3], ["c", 1], ["etc", 1]], columns
  end

  test "does not add an etc entry for fewer than top elements" do
    assert_equal [["a", 5], ["b", 3]], chart_columns({"a" => 5, "b" => 3})
  end

  test "does not add an etc entry for an empty collection" do
    assert_equal [], chart_columns({})
  end

  test "accepts an already-sorted array of pairs without mutating it" do
    pairs = [["a", 5], ["b", 3], ["c", 1], ["d", 1]]
    original = pairs.dup
    chart_columns(pairs)
    assert_equal original, pairs
  end

  test "respects a custom top" do
    columns = chart_columns({"a" => 4, "b" => 3, "c" => 2, "d" => 1}, top: 2)
    assert_equal [["a", 4], ["b", 3], ["etc", 3]], columns
  end
end
```

`chart_columns` 自体のテストは DB を使わないため fixtures に依存しない。0/1/2/3/4件という境界と、Hash/Array 両方の入力、非破壊性を直接カバーする。

### 変更5: 6箇所のビューを `chart_columns` に置き換え

対象: `app/views/stats/_recent_bounced.html.erb`

```erb
<%# 変更前（:72-77, :90-95 の2箇所、同型） %>
<% if @count_by_destination.present? %>
  <%= javascript_tag do %>
    c3.generate({
      bindto: '#count_by_destination',
      size: {height: 300},
      data: {
        columns: <%= raw(
          @count_by_destination.to_a.slice(0, 10)
            .push(['etc', @count_by_destination.values.slice(3..-1).try(:sum)])
            .select {|_, v| v.present? }
            .inspect
        ) %>,
        type : 'pie'
      }
    });
  <% end %>
<% end %>

<%# 変更後 %>
<% if @count_by_destination.present? %>
  <%= javascript_tag do %>
    c3.generate({
      bindto: '#count_by_destination',
      size: {height: 300},
      data: {
        columns: <%= raw chart_columns(@count_by_destination).inspect %>,
        type : 'pie'
      }
    });
  <% end %>
<% end %>
```

`@count_by_reason` も同じ形で置き換える。

対象: `app/views/stats/_unique_recipient_bounced.html.erb`

`@uniq_count_by_destination` / `@uniq_count_by_reason` / `@uniq_count_by_sender` の3箇所とも、`columns:` の中身を `<%= raw chart_columns(@uniq_count_by_X).inspect %>` に置き換える。`present?` ガードと `No data in this period.` の表示条件（#36 で追加済み）はそのまま残す。

対象: `app/views/stats/_bounced_by_type.html.erb`

```erb
<%# 変更前 %>
<% chunk.each do |reason, count_by_destination| %>
  <% count_by_destination = count_by_destination.sort_by(&:last).reverse %>
  <%= javascript_tag do %>
    c3.generate({
      bindto: '<%= "#bounced_by_#{reason}" %>',
      data: {
        columns: <%= raw(
          count_by_destination.slice(0, 10)
            .push(['etc', count_by_destination.map(&:last).slice(3..-1).try(:sum)])
            .select {|_, v| v.present? }
            .inspect
        ) %>,
        type : 'donut'
      },
      donut: {
        title: '<%= reason %>',
      }
    });
  <% end %>
<% end %>

<%# 変更後 %>
<% chunk.each do |reason, count_by_destination| %>
  <% count_by_destination = count_by_destination.sort_by(&:last).reverse %>
  <%= javascript_tag do %>
    c3.generate({
      bindto: '<%= "#bounced_by_#{reason}" %>',
      data: {
        columns: <%= raw chart_columns(count_by_destination).inspect %>,
        type : 'donut'
      },
      donut: {
        title: '<%= reason %>',
      }
    });
  <% end %>
<% end %>
```

`count_by_destination` は Array（`[destination, count]` のソート済み配列）のまま `chart_columns` に渡す。`chart_columns` 内部で `.to_a` を呼んでも self が返るだけだが、`first`/`drop` はいずれも非破壊なので呼び出し元の変数は変更されない。

### 変更6: stale テストの修正

対象: `test/controllers/status_controller_test.rb`

```ruby
# 変更前
require 'test_helper'

class MonitorControllerTest < ActionDispatch::IntegrationTest
  test "should get index" do
    get monitor_index_url
    assert_response :success
  end

end

# 変更後
require 'test_helper'

class StatusControllerTest < ActionDispatch::IntegrationTest
  test "should get index" do
    get status_url
    assert_response :success
  end
end
```

`StatusController#index` の集計窓は `Time.now` を都度計算するため、fixtures の固定過去日時は対象に入らない。ルーティングの是正と HTTP 200 のスモークに留め、JSON の中身は断言しない。

### 変更7: `StatsController#index` の統合テスト

対象: `test/controllers/stats_controller_test.rb`（新規）

```ruby
require "test_helper"

class StatsControllerTest < ActionDispatch::IntegrationTest
  test "reflects the given date range in the aggregation blocks" do
    get root_path, params: { from: "2026-08-01", to: "2026-08-02" }

    assert_response :success
    assert_includes response.body, "2026-08-01 〜 2026-08-02"
    assert_includes response.body, "test1.example.com"
    assert_includes response.body, "test2.example.com"
    assert_not_includes response.body, "excluded-before.example.com"
    assert_not_includes response.body, "excluded-after.example.com"
  end

  test "shows No data in this period for a range with no bounces" do
    get root_path, params: { from: "2020-01-01", to: "2020-01-02" }

    assert_response :success
    assert_includes response.body, "No data in this period."
  end
end
```

1本目は変更3の fixtures（`boundary_start` / `boundary_end` が範囲内、`day_before_start` / `boundary_next_day` が範囲外）をそのまま使う。期間ラベルの表示、範囲内destinationの反映、範囲外destinationの非表示を1つのリクエストで確認する。2本目は fixtures のどれとも重ならない固定の過去期間を指定し、空データ時の表示を確認する。「8チャートが描画される」ことをチャートの絶対数で数えるのではなく、期間フィルタが利いているかどうかを本文の文字列で確認する形にした(research.md で指摘したとおり、`bounced_by_type` は reason 数だけドーナツが増減するため絶対数のアサーションは不安定になる)。

## 影響範囲

既存テストへの影響: `status_controller_test.rb` は現在実行すれば `NameError` で落ちる状態なので、修正により初めて成立するようになる。他に既存の自動テストは無い。

API 変更なし。ルーティングの変更もない。マイグレーションもない（`db/schema.rb` は変更しない）。

`etc` 修正によりチャートの見た目が変わる。個別表示件数が10件から3件に減り、4〜10位だった項目は個別表示から消えて `etc` に吸収される。チャート合計の数値は二重計上が無くなり正しくなる。Issue #38 に記載済み。

CI の実行時間が増える。既存の `bundler-audit`（約25秒）に加えて、MySQL サービスコンテナの起動・healthcheck 待ち・`bundle install`・`db:create db:schema:load`・`bin/rails test` が加わる。

## 考慮事項

`DATABASE_URL` による接続先の上書きは、`config/database.yml` を変更せずに CI 特有の接続問題（`host: localhost` のソケット優先解決）を避けるための処置であり、ローカル開発環境や Pi の挙動には影響しない。

`DISABLE_SPRING=1` は CI 環境でのみ設定し、既存の `bin/spring` を使ったローカル開発・Pi のワークフローには影響しない。

`TZ: UTC` も CI 環境でのみ設定する。Pi は TZ=Asia/Tokyo で動作しており(CLAUDE.md)、この設定はローカル開発・Pi の挙動を変えない。CI で `TZ` を明示するのは、fixtures の日時文字列が意図どおりの瞬間として保存されることを保証するためであり、technically な保険ではなく変更3の fixtures 設計が成立するための前提条件である。

fixtures の日付（2026-08-01/02）は固定の過去日付であり、`Date.today` には一切依存しない。時間が経過してもこれらのテストの結果は変わらない。ただし、この決定性は `TZ: UTC` とセットで初めて成立する。`TZ` が未設定または UTC 以外だと、fixtures の日時文字列は同じ YAML のまま実際に格納される時刻が変わり得る(research.md で `TZ=UTC` / `TZ=Asia/Tokyo` / `TZ=America/Los_Angeles` それぞれで別の時刻・日付になることを実測済み)。

`chart_columns` の変更によりビューの表示範囲は10件から3件に減るが、これは二重計上を直すために必須の変更ではなく、凡例を見やすくするための独立した選択（`first(N)` + `drop(N).sum` は N がいくつでも合計が一致するため）。research.md に経緯を記録済み。

CI が初めて赤くなる可能性がある箇所は、`DATABASE_URL` 経由の接続、および `stats#index` の統合テストがレイアウト経由でアセットパイプライン（Sprockets + dartsass-sprockets）を要求する点。実装順序として、まず CI ワークフローと最小のテスト（`status_controller_test.rb` の修正、`bounce_mail_test.rb`）を先に通し、`test.yml` が緑になったことを確認してから `chart_columns` と6箇所のビュー修正・統合テストに進む。

## 残決定事項

無し。spec.md の残決定事項3件（B/A/B）で主要な設計判断は確定しており、本計画はその実行に必要な実装詳細を埋めるものにとどまる。CI の `DATABASE_URL` / `DISABLE_SPRING` は技術的なリスク回避であり、トレードオフを伴う選択ではないため、annotation サイクルでの判断事項としては挙げていない。

## タスクリスト

大区分は独立実装可能な「ユニット」でまとめる。ユニット A → B → C は順序依存があり並列不可（B はローカル変更だけでは検証できず、実際に CI を走らせて緑になることを確認する外部ゲートを含むため）。ユニット内のタスクは上から順に実施する。

### ユニットA: test 環境の是正・fixtures・境界条件テスト・stale テスト修正（並列不可: 依存 = なし）

CI に乗せる前にローカルで用意できるものをまとめる。ここまではファイル編集のみで、実行して確認することはできない（ローカルに MySQL が無いため）。

- [x] A-1: `config/environments/test.rb` の `show_exceptions` を `:none` に修正する（変更1）
- [x] A-2: `test/fixtures/bounce_mails.yml` を `DEFAULTS` アンカーを使う形で追加する（変更3）
- [x] A-3: `test/models/bounce_mail_test.rb` を追加し、`within_period` の境界条件4点（下限含む・上限含む・前日除外・翌日除外）をテストする（変更3）
- [x] A-4: `test/controllers/status_controller_test.rb` を `StatusControllerTest` / `status_url` に修正する（変更6）

### ユニットB: CI ワークフローの追加とグリーン化確認（並列不可: 依存 = ユニットA）

ここが唯一、ローカルでは検証できず実際に CI を走らせる必要があるゲート。ユニットC に進む前に、最小構成のテストで CI が通ることを確認する。

- [x] B-1: `.github/workflows/test.yml` を追加する。MySQL 8.0 サービスコンテナ、`TZ: UTC`、`DATABASE_URL`、`DISABLE_SPRING=1` を含める（変更2）
- [x] B-2: ユニットA・B-1の変更をブランチに反映してリモートに push し、GitHub Actions 上で `test` ワークフローが成功することを確認する。失敗した場合は原因（MySQL接続、TZ、アセットパイプラインなど）を切り分けてから次に進む

### ユニットC: `chart_columns` の追加とビュー6箇所の置き換え、統合テスト（並列不可: 依存 = ユニットB。C-2〜C-5 は互いに並列可）

CI が最小構成で緑になったことを確認してから着手する。C-1（ヘルパー本体）だけ先に必要。C-2〜C-5 は別ファイルで互いに依存しないため、subagent へ分けて同時に進めてよい。

- [x] C-1: `app/helpers/stats_helper.rb` に `chart_columns(collection, top: 3)` を追加する（変更4）
- [x] C-2: `test/helpers/stats_helper_test.rb` を追加し、0/1/2/3/4件・top変更・非破壊性をテストする（変更4）
- [x] C-3: `app/views/stats/_recent_bounced.html.erb` の2箇所（`count_by_destination`・`count_by_reason`）を `chart_columns` 呼び出しに置き換える（変更5）
- [x] C-4: `app/views/stats/_unique_recipient_bounced.html.erb` の3箇所（`uniq_count_by_destination`・`uniq_count_by_reason`・`uniq_count_by_sender`）を置き換える（変更5）
- [x] C-5: `app/views/stats/_bounced_by_type.html.erb` の1箇所（Array入力）を置き換える（変更5）
- [x] C-6: `test/controllers/stats_controller_test.rb` を追加し、期間フィルタの反映・期間ラベル表示・空期間表示をテストする（変更7）
- [x] C-7: 変更をブランチに反映して push し、GitHub Actions 上で `test` ワークフローが緑のままであることを確認する
