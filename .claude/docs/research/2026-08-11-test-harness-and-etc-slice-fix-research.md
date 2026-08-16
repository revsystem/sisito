# テスト基盤の整備と etc 二重計上の修正 調査レポート

日時: 2026-08-11

設計仕様: [.claude/docs/specs/2026-08-11-test-harness-and-etc-slice-fix-spec.md](../specs/2026-08-11-test-harness-and-etc-slice-fix-spec.md)

## 対象範囲

読んだファイルは以下のとおり。

- `test/test_helper.rb`、`test/controllers/status_controller_test.rb`
- `test/` 配下のディレクトリ構成（`.keep` の有無）
- `config/environments/test.rb`、`config/database.yml`、`config/secrets.yml`
- `config/routes.rb`
- `.github/workflows/bundler-audit.yml`、直近の実行ログ（`gh run view --log`）
- `Gemfile`、`mise.toml`
- `db/schema.rb`（`bounce_mails` / `whitelist_mails` の全カラム）
- `db/migrate/20170128144003_example_data.rb`
- `app/controllers/stats_controller.rb`、`app/controllers/status_controller.rb`、`app/controllers/application_controller.rb`
- `app/models/bounce_mail.rb`
- `app/helpers/stats_helper.rb`
- `app/views/stats/_recent_bounced.html.erb`、`_unique_recipient_bounced.html.erb`、`_bounced_by_type.html.erb`
- `app/views/layouts/application.html.erb`
- actionpack 7.2.3.2 の `lib/action_dispatch/middleware/exception_wrapper.rb`（Pi 上の `vendor/bundle` で実物を確認）
- activerecord 7.2.3.2 の `lib/active_record/migration.rb`、`lib/active_record/tasks/database_tasks.rb`、`lib/active_record/schema.rb`、`lib/active_record/connection_adapters/abstract/schema_statements.rb`、`lib/active_record/railties/databases.rake`（Pi 上の `vendor/bundle` で実物を確認。`Gemfile.lock` と一致するため CI に入る gem と同一）
- activerecord 7.2.3.2 の `lib/active_record/fixtures.rb`、`lib/active_record/fixture_set/file.rb`、`lib/active_record/fixture_set/table_row.rb`、`lib/active_record/connection_adapters/abstract/database_statements.rb`、`lib/active_record/connection_adapters/abstract/quoting.rb`、`lib/active_record/connection_adapters/mysql/quoting.rb`（fixtures の読み込み・型変換・SQL生成の経路）
- activemodel 7.2.3.2 の `lib/active_model/type/date_time.rb`
- `ActiveSupport::ConfigurationFile`（fixtures YAML の読み込み方式）
- Ruby の `Array#slice` / `Array#to_a` / `Array#drop` の挙動、YAML の日時文字列パースと `Time#getlocal` の挙動（`mise exec -- ruby -e` および `TZ=X mise exec -- ruby` によるプロセス分離実測）

## 既存類似実装

類似度は高い。#36（PR #37）で `BounceMail.within_period` scope と `StatsHelper#stats_period_label` を追加した実績があり、今回の `chart_columns` ヘルパーも同じ「6箇所の重複を1箇所に集約する」パターンの繰り返しになる。採用方針は #36 のパターンを踏襲する（`StatsHelper` にメソッドを足し、ビュー側は呼び出すだけにする）。

CI ワークフローの類似実装は `.github/workflows/bundler-audit.yml` のみで、ジョブ構成（`actions/checkout@v4` → `ruby/setup-ruby@v1` with `bundler-cache: true`）をそのまま流用できる。ただしこのワークフローはデータベースを使わないため、MySQL サービスコンテナの部分は新規に書く必要がある。

## 既存パターンと規約

### テストの命名・配置規約

`test/` は Rails 標準の Minitest 構成で、`test_helper.rb` が `ENV['RAILS_ENV'] ||= 'test'` → `config/environment` → `rails/test_help` の順に読み込み、`ActiveSupport::TestCase` に `fixtures :all` を仕込んでいる。既存の唯一の実テストファイルはコントローラ配下に `ActionDispatch::IntegrationTest` を継承する形で書かれており（`test/controllers/status_controller_test.rb`）、`get monitor_index_url` のように名前付きルートヘルパーを使う。今回追加するテストもこの規約に従う。

`test/models/.keep`、`test/helpers/.keep`、`test/fixtures/.keep`（`files/.keep` も含む）が既に存在し、対応するディレクトリは作成済みだが中身が無い状態。`test/models/bounce_mail_test.rb`、`test/helpers/stats_helper_test.rb`、`test/fixtures/bounce_mails.yml` はこの空ディレクトリに新規追加する形になる。

### CI ワークフローの規約

`bundler-audit.yml` は `on: push (master) / pull_request / schedule (weekly)` の3トリガー構成で、`ruby/setup-ruby@v1` に `ruby-version` を明示していない。直近の実行ログ（`gh run view --log`）で `ruby-version: default` → `Using 3.4.9 as input from file mise.toml` → `ruby 3.4.9` のインストールが確認でき、リポジトリに `.ruby-version` が無くても `mise.toml` の `ruby = "3.4.9"` を自動検出することが実証済みである。新設する `test.yml` も同じ `ruby/setup-ruby@v1` の使い方で Ruby バージョンの整合を取れる。

### ヘルパーへの集約規約

#36 で確立した規約は「重複する定型ロジックを `StatsHelper` の1メソッドに集約し、呼び出し元は薄くする」というもの。`stats_period_label(from, to)` が前例になる。今回の `chart_columns(collection, top: 3)` もこの規約を踏襲する。

## 重要な発見

### `config.action_dispatch.show_exceptions = false` は Rails 7.2 で意図と逆に働く

`config/environments/test.rb` の該当行は Rails 標準テンプレートの古い書き方（boolean）のまま残っている。actionpack 7.2.3.2 の `ExceptionWrapper#show?`（`lib/action_dispatch/middleware/exception_wrapper.rb`）は次の case 式で判定する。

```ruby
def show?(request)
  config = request.get_header("action_dispatch.show_exceptions")
  case config
  when :none
    false
  when :rescuable
    rescue_response?
  else
    true
  end
end
```

`false` は `:none` にも `:rescuable` にも一致しないため `else` に落ち、`true`（例外ページを表示する＝例外を re-raise しない）と解釈される。したがって現状のまま統合テストを書くと、コントローラ内で例外が起きても Minitest には伝播せず 500 のレンダリングになり、失敗理由が読み取りにくくなる。`:none` に変更することで、テスト内の例外は素通しで re-raise され、通常の Ruby の例外としてテスト失敗の原因になる。

### `db:migrate` は非決定的なデータを投入する

`db/migrate/20170128144003_example_data.rb` は `(1..100).flat_map { ... }` で `BounceMail.create!` を700回呼び、各レコードの `timestamp` / `created_at` / `updated_at` に `Date.today - rand(14).days` を使う。実行するたびに異なる日付・組み合わせのデータが入るため、境界条件を固定日付で検証するテストとは原理的に両立しない。加えて `WhitelistMail.create!` も3行、`Date.today` を基準にした日付で投入する。

`db/schema.rb` にはデータが含まれないため、CI では `db:schema:load` に固定し、`db:migrate` の実行（＝このマイグレーションを含む全履歴の適用）を避ける必要がある。

### `db:schema:load` だけで `maintain_test_schema!` は素通りする

Rails は `test_helper.rb` の `require 'rails/test_help'` 経由で `ActiveRecord::Migration.maintain_test_schema!` を自動的に呼ぶ。これが「pending migrations」エラーでテスト実行を止める可能性があるかどうかを、Pi 上の実物の gem（`vendor/bundle/ruby/3.4.0/gems/activerecord-7.2.3.2`。`Gemfile.lock` と一致するため CI で入る gem と同一）のソースを読んで確認した。

`maintain_test_schema!` は `load_schema_if_pending!` を呼び、その中身は次の2段構えになっている（`lib/active_record/migration.rb:716-728`）。

```ruby
def load_schema_if_pending!
  if any_schema_needs_update?
    system("bin/rails db:test:prepare")
  end
  check_pending_migrations
end
```

`any_schema_needs_update?` は `schema_up_to_date?`（`lib/active_record/tasks/database_tasks.rb:389-402`）を呼び、`ar_internal_metadata` テーブルの `schema_sha1` と現在の `db/schema.rb` の sha1 を比較する。`db:schema:load` タスク（`schema:load` → `DatabaseTasks.load_schema_current` → `DatabaseTasks.load_schema`、`lib/active_record/railties/databases.rake:502` と `lib/active_record/tasks/database_tasks.rb:368-387`）は、schema.rb を読み込んだ直後に `internal_metadata.create_table_and_set_flags(db_config.env_name, schema_sha1(file))` で正しい sha1 を書き込む。したがって CI で標準の `bin/rails db:schema:load` を使う限り `schema_up_to_date?` は `true` を返し、`db:test:prepare` の再実行（システムコール）は起きない。

`check_pending_migrations` は無条件に呼ばれ、`db/migrate/*.rb` のバージョンが `schema_migrations` テーブルに記録済みかを見る。ここで鍵になるのが `ActiveRecord::Schema.define`（`lib/active_record/schema.rb:54-62`）が呼ぶ `connection.assume_migrated_upto_version(info[:version])` の実装（`lib/active_record/connection_adapters/abstract/schema_statements.rb:1340-1359`）である。

```ruby
def assume_migrated_upto_version(version)
  ...
  versions = migration_context.migrations.map(&:version)
  ...
  inserting = (versions - migrated).select { |v| v < version }
  ...
  execute insert_versions_sql(inserting)
end
```

`migration_context.migrations` は `db/migrate/` に存在する全マイグレーションファイルを（実行するかどうかに関わらず）走査してバージョン番号を集める。`schema.rb` の `version:`（`2026_04_25_000001`）より小さい全バージョンが、実際にはマイグレーションの `change`/`up` を1行も実行しないまま `schema_migrations` に挿入される。つまり `20170128144003_example_data.rb` のバージョンも「migrated 済み」としてマークされる一方、その中身（`Date.today - rand(14).days` での700行投入）は一切実行されない。

以上から、CI で `db:create` → `db:schema:load` の順に実行してから `rails test` を走らせれば、`maintain_test_schema!` は `schema_sha1` の一致で早期リターンし、`pending_migrations` も空になるため、`PendingMigrationError` は発生しない。`ActiveRecord.maintain_test_schema = false` のような回避策は不要で、標準のタスク呼び出しだけで足りる。

### fixtures の必須カラムと落とし穴

`bounce_mails` は `id` を除き 24 カラムあり、`digest`（`default: ""`）以外はすべて `null: false` かつデフォルト値を持たない。fixtures で共通デフォルトを素朴な YAML アンカー（トップレベルキー名を自分で決めて `&anchor` にする）で作ると、そのキー自体が1件の `bounce_mails` フィクスチャとして解釈され、集計・件数のテストに余分な1行が混入しかねない。ただし Rails の fixtures にはこの状況にちょうど対応する組み込み機能があり、`lib/active_record/fixtures.rb:435-455` のコメントに明記されている。トップレベルキーを大文字の `DEFAULTS` にすると、`FixtureSet#ignored_fixtures`（同ファイル）が `@ignored_fixtures << "DEFAULTS"` を無条件に行い、このキーは実データとして挿入されない。「実在するレコード名をアンカーにする」よりもこちらが Rails 標準の書き方であり、採用する。

`whitelist_mails` は `digest` が `null: false` かつデフォルト値なしで、`recipient` / `senderdomain` はデフォルト `""` を持つ。今回追加するテスト（`within_period` の境界条件、`chart_columns` の等価性、`status` のスモーク、`stats#index` の統合テスト）はいずれも `whitelist_mails` を参照するコードパスに触れないため、このテーブルの fixtures は不要と判断できる。

### fixtures の日時は CI ランナーの TZ に依存して意味が変わる

`bounce_mails.timestamp` のような datetime 型カラムに fixtures でオフセット無しの日時文字列（例: `2026-08-01 00:00:00`）を書くと、実際に DB に格納される値は fixtures を読み込むプロセスの `TZ` 環境変数に依存する。この依存は暗黙的で、CLAUDE.md が要求する「fixtures は `Date.today` に依存せず決定的であること」という前提を静かに破りうる。以下の経路で確認した。

fixtures の YAML は `ActiveSupport::ConfigurationFile#parse` が ERB 展開後に `YAML.unsafe_load` でパースする（Psych の素の日時パース）。オフセット無しの日時文字列は Psych の暗黙型解決により UTC の瞬間として解釈されるが、返される `Time` オブジェクトはプロセスのローカルタイムゾーンに変換済みの表現になる。これは `mise exec -- ruby` でプロセスを分けて実測して確認した。

```
$ TZ=UTC mise exec -- ruby -ryaml -e 'p YAML.unsafe_load("t: 2026-08-01 00:00:00")["t"]'
2026-08-01 00:00:00 +0000
$ TZ=Asia/Tokyo mise exec -- ruby -ryaml -e 'p YAML.unsafe_load("t: 2026-08-01 00:00:00")["t"]'
2026-08-01 09:00:00 +0900
$ TZ=America/Los_Angeles mise exec -- ruby -ryaml -e 'p YAML.unsafe_load("t: 2026-08-01 00:00:00")["t"]'
2026-07-31 17:00:00 -0700
```

同じ YAML 文字列が、パースするプロセスの `TZ` によって異なる時刻（日付をまたぐ場合すらある）の `Time` オブジェクトになる。

fixtures の挿入 SQL は `build_fixture_sql`(`lib/active_record/connection_adapters/abstract/database_statements.rb:558-577`)が `type.serialize(fixture[name])` でカラム型にキャストし、`datetime` 型（`ActiveModel::Type::DateTime#cast_value`、`lib/active_model/type/date_time.rb`）は値がすでに `Time` オブジェクトなら文字列パースをスキップしてそのまま使う。最終的に Arel が SQL リテラルへ変換する際、`Time` 値は `quoted_date`（`lib/active_record/connection_adapters/abstract/quoting.rb:184-198`）を経由し、`default_timezone == :local` のとき `value.getlocal` が呼ばれる。`config/application.rb:22` の `config.active_record.default_timezone = :local` によりこの分岐が使われる。

つまり fixtures の日時文字列は「Psych がプロセスの TZ で解釈した時刻」が「その TZ のまま」DB に書き込まれる。GitHub Actions の `ubuntu-latest` ランナーは既定で `Etc/UTC` だが、これは実装が依存してよい明文化された契約ではなく、ランナーイメージの既定値である。fixtures にオフセット無しの日時文字列を書く設計は、CI の実行環境の TZ に暗黙に依存することになり、日付境界を1秒単位で検証する `within_period` の境界条件テストにとってはこの依存が致命的になりうる（`TZ` が UTC からずれると、`boundary_start`/`boundary_end` の実際の格納値が日付をまたいでずれ、意図した境界と異なる境界を検証してしまう）。

対策として、CI ジョブの `env` に `TZ: UTC` を明示的に設定し、fixtures の日時文字列は UTC 前提の値として書く。これによりランナーの既定値に依存せず、意図と保存値が常に一致することを保証する。

### `StatusController#index` は現在時刻基準の集計窓を持つ

```ruby
interval = (Rails.application.config.sisito.dig(:status, :interval) || 60).to_i
start_time = Time.now - interval
status = cache_if_production(:status, expires_in: interval - 5) do
  bounce_mails = BounceMail.where('timestamp >= ?', start_time - interval).to_a
  ...
```

集計対象は「実行時刻から `2 × interval`（既定 120 秒）以内」に限られる。fixtures に入れる固定の過去日時（境界条件検証用の日付）はこの窓の外側になるため、`bounce_mails` の件数を fixtures 経由で断言するテストは書けない。ルーティングの是正（`monitor_index_url` → `status_url`）と HTTP 200 のスモーク確認に留めるのが妥当で、JSON の中身を検証するなら `travel_to` で時刻を固定するか、実行都度計算した時刻を使う必要があり、今回のスコープには含めない。

### `chart_columns` が担うべき正確な契約

6箇所の現行コードはすべて次の形を持つ（`_bounced_by_type` のみ入力がソート済み Array、他5箇所は Hash）。

```ruby
collection.to_a.slice(0, 10)
  .push(['etc', <values>.slice(3..-1).try(:sum)])
  .select {|_, v| v.present? }
```

個別表示 10 件・`etc` 集計対象4件目以降という不一致が二重計上の原因（research.md 2026-08-10 版で既出）。新設する `chart_columns(collection, top: 3)` はこの `top` を単一の情報源にし、個別表示・`etc` 集計とも同じ `top` を使う。

`etc` を出すかどうかの判定には、既存コードの `try(:sum)` → `present?` という経路を単純に踏襲してはいけない。Ruby の `Array#slice(range)` は、開始位置が配列長と等しいとき `[]` を返し、配列長を超えるとき `nil` を返す（`mise exec -- ruby` での実測で確認）。

```
[1,2,3].slice(3..-1)   => []    (配列長3、開始位置3 = 長さと等しい)
[1,2].slice(3..-1)     => nil   (配列長2、開始位置3 > 長さ)
[1,2,3,4].slice(3..-1) => [4]
```

現行コードの `values.slice(3..-1).try(:sum)` は、対象が0〜2件のときは `nil.try(:sum)` で `nil` になり `present?` で弾かれ `etc` が出ない。しかし対象がちょうど3件のときは `[].try(:sum)` が `0` を返し、`0.present?` は `true` であるため、**現行コードは既にこの境界（ちょうど3件）で `etc: 0` を出している**。これは推測ではなく、本調査中に Pi 上で再現して確認した事実である。まず `bounce_mails` から destination がちょうど3種類になる reason・日付の組を SQL で特定した。

```sql
SELECT reason, DATE(timestamp) AS d, COUNT(DISTINCT destination) AS n
FROM bounce_mails
WHERE timestamp >= "2026-08-01" AND timestamp < "2026-08-16"
GROUP BY reason, DATE(timestamp)
HAVING n = 3
ORDER BY d DESC LIMIT 5;
-- => mailboxfull 2026-08-09 3
```

`reason=mailboxfull` かつ `2026-08-09` の destination 内訳を確認すると `icloud.com: 6, gmail.com: 4, softbank.ne.jp: 2` の3件だった。この日付をそのまま `from`/`to` に指定して Pi 上の稼働中インスタンスにリクエストを送った。

```
curl 'http://localhost:1080/?from=2026-08-09&to=2026-08-09'
```

返ってきた HTML から `#bounced_by_mailboxfull` の `c3.generate` ブロックを抜き出すと次のとおりだった。

```
columns: [["icloud.com", 6], ["gmail.com", 4], ["softbank.ne.jp", 2], ["etc", 0]]
```

3件の個別スライスに加えて `["etc", 0]` が実際に出力されている。境界（ちょうど3件）で `etc: 0` が混入するという Ruby の意味論上の予測が、稼働中のコードで確かに発生することを確認した。

したがって `chart_columns` の実装は、`slice(top..-1)`（要素数不足時に `nil` を返し得る）ではなく `drop(top)`（要素数によらず必ず `Array` を返し、0件残りなら `[]`）を使い、判定は `present?`（`0` を通してしまう）ではなく `.empty?` で行う必要がある。`slice` のまま `.empty?` に変えるだけだと、0〜2件残りのケースで `nil.empty?` の `NoMethodError` になるため、切り出し方法と判定方法は対で変える。

もう一点、`chart_columns` は Hash と `[key, count]` の pair 配列の両方を受け取る設計にするため、内部では常に pair 配列として扱うことになる。このとき残り部分の合計は `pairs.drop(top).sum` とは書けない。`sum` はブロック無しだと各要素を `+` で足そうとし、要素が `[key, count]` という2要素配列なので `TypeError: Array can't be coerced into Integer` になる（`mise exec -- ruby` で実測済み）。現行コードが `hash.values.slice(...)` や `count_by_destination.map(&:last).slice(...)` のように事前に count だけを取り出しているのはこのためで、`chart_columns` では `pairs.drop(top).sum {|_, v| v }` のように明示的に count を取り出すブロックが要る。この点は `ruby -c` の構文チェックでは検出できず、Plan フェーズのコードスニペットと単体テスト（0/1/2/3/4件のケース）で担保する。

### `top: 3` は正しさではなく見やすさの選択

`etc` の二重計上を直すこと自体は、個別表示件数を何件にしても実現できる。個別表示を `first(N)`、`etc` を `drop(N).sum` にすれば、N が10でも3でも合計は元のコレクションの合計と必ず一致する。つまり「個別表示を3件に揃える」（spec の要件ごとの実装方針、AskUserQuestion で N=3 を選択）は二重計上を直すために必須の変更ではなく、チャートの凡例を短くして見やすくするための独立した選択である。この経緯は spec / Issue #38 に記録されているが、次にこのコードを読む人が「バグを直すには表示件数を減らすしかなかった」と誤解しないよう、ここに明記しておく。

### `Array#to_a` は Array に対して self を返す

```ruby
a = [1,2,3]
a.to_a.equal?(a)  # => true
```

`_bounced_by_type.html.erb` から渡される `count_by_destination`（`sort_by(&:last).reverse` 済みの Array）に対して `chart_columns` 内で `.to_a` を呼んでも、新しいオブジェクトは作られない。ここで `push` のような破壊的メソッドを直接使うと呼び出し元の変数まで書き換わる。ただし `Array#first(n)` と `Array#drop(n)` はどちらも非破壊的で常に新しい配列を返すため、`columns = pairs.first(top)` のように非破壊メソッドで新しい配列を作ってから、その新しい配列に対して `<<` で `etc` 行を追加する設計にすれば、`pairs`（＝呼び出し元の Array がそのまま渡ってきている可能性がある変数）自体は変更されない。旧コードも `.to_a.slice(0, 10)` の `slice` が新しい配列を返すため実害は無かったが、ヘルパーとして切り出す際に `first`/`drop` を経由する設計を維持する必要がある。

### `stats#index` の統合テストにおける日付の非決定性

```ruby
@recent_days_to = params[:to].present? ? params[:to].to_date : Date.today
default_recent_days = Rails.application.config.sisito.fetch(:default_recent_days, 14)
@recent_days_from = params[:from].present? ? params[:from].to_date : @recent_days_to - default_recent_days
```

`params[:from]`/`[:to]` を指定しないリクエストは `Date.today` を基準に既定期間（14日）を計算する。fixtures の日付を固定しても、テストが `params` を渡さずにデフォルト期間に頼ると、実行日によって fixtures の日付が対象期間の内外を行き来し、テストが非決定的になる。統合テストは必ず `get root_path, params: { from: ..., to: ... }` のように固定の `from`/`to` を明示し、fixtures の日付と一致させる。

「8チャートが描画される」という表現も正確ではない。`StatsController#index` が持つ集計ブロックは8つ（`@count_by_date` 他3つ、`@uniq_count_by_*` 3つ、`@bounced_by_type` 1つ）だが、`_bounced_by_type.html.erb` は `@bounced_by_type` の reason 数だけ `c3.generate` ブロックを生成する（`each_slice` ループ）。したがって「描画されるチャートの絶対数」ではなく「8つの集計ブロックそれぞれが期間フィルタを反映していること」を確認する、という言い方が正確である。

### レイアウトはアセットパイプラインを経由する

`app/views/layouts/application.html.erb` は `stylesheet_link_tag 'application'` と `javascript_include_tag 'application'` を持つ。`stats#index` はこのレイアウトでレンダリングされるため、統合テストで `get root_path` を叩くとアセットパイプライン（Sprockets + dartsass-sprockets、Terser）がテスト環境で解決できる必要がある。CI 上で `bundle install` 後にこの経路が動くかどうかは、テストを実際に走らせて確認する必要がある事項であり、Plan フェーズで CI ワークフローの手順に組み込む。

## 注意点・リスク

`config/environments/test.rb` の変更は `show_exceptions` の1行に留める。この環境ファイルには他にも `config.cache_classes = true`、`config.eager_load = false` など標準的な設定があるが、今回のスコープはテストを通すことであり、Rails 7.2 向けの網羅的なモダナイズは行わない。

`etc` の修正はチャートの表示数値を変える。個別表示件数を10件から3件に減らすため、これまで4〜10位に表示されていた項目が個別表示から消え `etc` に吸収される。数値の正しさは改善するが、画面の見た目（表示される個別ラベルの数）が変わる点は Issue #38 に記載済みで、リリース時に改めて周知する。

CI にジョブを追加すると、既存の `bundler-audit`（約25秒）に加えて MySQL サービスコンテナの起動・`bundle install`・`db:schema:load`・テスト実行が加わり、PR ごとの待ち時間が増える。基盤整備の初回はこの増分を許容する前提で進める。

## バグ調査の場合

該当箇所は次の6箇所。個別表示・`etc` 集計とも `top: 3` に統一する。

- `app/views/stats/_recent_bounced.html.erb:72-77`（`count_by_destination`）
- `app/views/stats/_recent_bounced.html.erb:90-95`（`count_by_reason`）
- `app/views/stats/_unique_recipient_bounced.html.erb:30-35`（`uniq_count_by_destination`）
- `app/views/stats/_unique_recipient_bounced.html.erb:50-55`（`uniq_count_by_reason`）
- `app/views/stats/_unique_recipient_bounced.html.erb:67-72`（`uniq_count_by_sender`）
- `app/views/stats/_bounced_by_type.html.erb:29-34`（reason 別、入力が Hash ではなく Array）

再現手順は、任意の期間で destination（または reason／sender）の種類数がちょうど3件になるような絞り込みを行い、レスポンス中の該当 `columns` に `["etc", 0]` が含まれることを確認する。#36 の Pi 検証時に `bounced_by_mailboxfull`（3件）で実際に観測済み。4件以上のケースでは `etc` の値が4件目以降の合計になり、個別表示の4〜10位と二重計上される（例: `bounced_by_userunknown` で10件中4〜10位の合計が `etc` にも含まれ、チャート合計が実件数を超える）。
