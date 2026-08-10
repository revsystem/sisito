# ダッシュボード日付範囲フィルタ 調査レポート

日時: 2026-08-10

設計仕様: [.claude/docs/specs/2026-08-10-stats-date-range-all-charts-spec.md](../specs/2026-08-10-stats-date-range-all-charts-spec.md)

## 対象範囲

読んだファイルは以下のとおり。

- `app/controllers/stats_controller.rb`（全 117 行）
- `app/controllers/application_controller.rb`（`cache_if_production` の定義）
- `app/controllers/status_controller.rb`（キャッシュ利用の別例として参照）
- `app/views/stats/index.html.erb`
- `app/views/stats/_recent_bounced.html.erb`
- `app/views/stats/_unique_recipient_bounced.html.erb`
- `app/views/stats/_bounced_by_type.html.erb`
- `app/models/bounce_mail.rb`
- `app/assets/javascripts/stats.js`
- `config/routes.rb` / `config/sisito.yml` / `config/initializers/sisito_performance.rb`
- `db/schema.rb`（`bounce_mails` のインデックス定義）
- `test/controllers/status_controller_test.rb`（既存テストの実態確認）

## アーキテクチャ概要

ダッシュボードは `root to: 'stats#index'`（config/routes.rb:2）の 1 アクションで完結している。`StatsController#index` が 8 個のインスタンス変数を組み立て、`index.html.erb` が 3 つのパーシャルに配って、各パーシャルが ERB で埋め込んだ生の JavaScript から `c3.generate()` を呼ぶ。サーバー側で集計済みの配列を JS リテラルとして直接展開する方式で、JSON API を介した非同期取得は存在しない。したがってチャートの再描画は必ずページ全体の再読み込みを伴い、「日付範囲を反映する」とはサーバー側のクエリを変えることと同義になる。

チャート描画箇所は `grep -rn "c3.generate" app/views` で 8 箇所、すべて `app/views/stats/` 配下にある。他のコントローラ（admin / bounce_mails / status など）はチャートを描画しない。

日付範囲と addresser の解決はアクション冒頭に集中している（stats_controller.rb:3-6）。

```ruby
@recent_days_to = params[:to].present? ? params[:to].to_date : Date.today
default_recent_days = Rails.application.config.sisito.fetch(:default_recent_days, 14)
@recent_days_from = params[:from].present? ? params[:from].to_date : @recent_days_to - default_recent_days
@addresser = params[:addresser]
```

`default_recent_days` は `config/sisito.yml:14` で 14 に設定されており、既定表示は「今日から遡って 14 日」となる。フォームは `_recent_bounced.html.erb:6-24` の `form_tag root_path, method: :get` で、from / to / addresser の 3 項目を GET パラメータとして送る。

インスタンス変数と描画先の対応は次のとおり。期間フィルタの有無で明確に前半と後半に分かれる。

| インスタンス変数 | 定義行 | 描画先 | 種類 | 期間フィルタ | キャッシュ |
|---|---|---|---|---|---|
| `@count_by_date` | :9 | `_recent_bounced` #count_by_date | bar | あり | 15分 |
| `@count_by_destination` | :24 | `_recent_bounced` #count_by_destination | pie | あり | 15分 |
| `@count_by_reason` | :33 | `_recent_bounced` #count_by_reason | pie | あり | 15分 |
| `@count_by_reason_date` | :42 | `_recent_bounced` #count_by_reason_date | line | あり | 15分 |
| `@uniq_count_by_destination` | :61 | `_unique_recipient_bounced` | donut | なし | 2時間 |
| `@uniq_count_by_reason` | :70 | `_unique_recipient_bounced` | pie | なし | 2時間 |
| `@uniq_count_by_sender` | :80 | `_unique_recipient_bounced` | pie | なし | 2時間 |
| `@bounced_by_type` | :100 | `_bounced_by_type` | donut × reason 数 | なし | 2時間 |

後半 4 ブロックは `unless Rails.application.config.sisito[:shorten_stats]` の中にある（stats_controller.rb:59）。ビュー側も同じ条件で分岐しており（index.html.erb:6）、コントローラとビューで同じフラグを二重に評価する構造になっている。`shorten_stats` の参照箇所はこの 2 つと `config/sisito.yml:27` のコメントアウトされた既定値のみで、現状は未設定＝有効（後半も描画される）。

## 既存類似実装

類似度は中。同一ファイル内の前半 4 ブロックが、今回入れたい期間フィルタをすでに実装している。

- `app/controllers/stats_controller.rb:10` — `BounceMail.where('timestamp >= ? AND timestamp < ?', @recent_days_from, @recent_days_to + 1.day)`
- 同 :25、:34、:44 に同一の式が反復されている（現時点で 4 箇所）

採用方針は「既存実装を拡張する」（spec の Phase 0 で方針 A に合意済み）。加えて残決定事項 1 で選択肢 B が選ばれたため、この述語を `BounceMail` の scope に切り出し、前半 4 箇所も含めて 8 箇所すべてを scope 経由に置き換える。

境界条件の扱いは `>= from AND < to + 1.day` である。`to` に指定した日を丸ごと含めるための書き方で、`<= to` と書くと `to` 当日の 00:00:00 以降が落ちる。後半へ展開する際にここを言い換えると、上下のチャートで合計が 1 日分ずれ、データ不整合として観測されてしまう。

`@count_by_date` だけは追加の後処理がある（stats_controller.rb:21）。

```ruby
(@recent_days_from..@recent_days_to).map {|d| [d, cbd.fetch(d, 0)] }.to_h
```

クエリ結果に存在しない日を 0 で埋めているため、この Hash は常に非空になる。これが `_recent_bounced.html.erb` で `#count_by_date` のチャートだけガードなしで描画されている理由である。

## 既存パターンと規約

命名は `@count_by_X` / `@uniq_count_by_X` で統一され、キャッシュキーはインスタンス変数名と同じ接頭辞にフィルタ値を `_` 連結する形になっている。ただし `@count_by_reason_date`（変数名）に対してキーは `count_by_date_reason_...`（stats_controller.rb:42）と順序が入れ替わっており、命名の一貫性は完全ではない。今回の変更では触らない。

集計クエリは 4 ブロックとも同じ骨格を持つ。

```ruby
relation = BounceMail  # または BounceMail.select(...) / BounceMail.where(...)
relation = relation.where(addresser: @addresser) if @addresser.present?
relation.group(...).count
```

`relation = BounceMail` はクラスオブジェクトをそのまま変数に入れており、`@addresser` が空のときは `BounceMail.distinct.group(...)` とクラス経由で呼ぶことになる。ActiveRecord のクラスメソッド委譲で動くため実害はないが、scope 化すると常に `ActiveRecord::Relation` になり型が揃う。

生 SQL は `Arel.sql()` でラップする規約が徹底されている（CLAUDE.md の Code Style にも明記）。`@uniq_count_by_sender`（stats_controller.rb:82-96）は SELECT 句に `CASE WHEN addresseralias = '' THEN addresser ELSE addresseralias END AS addresser_alias` を書き、`group(Arel.sql('addresser_alias'))` で SELECT エイリアスを GROUP BY している。MySQL 固有の許容に依存した書き方で、`where` を前段に挟んでも構造は変わらない。

ビュー側の JS 埋め込みは `<%= raw(...) %>` に Ruby の `Array#inspect` を通す方式で統一されている。Ruby の配列リテラル表記がそのまま有効な JS 配列リテラルになることを利用しており、JSON シリアライザは使っていない。

パイ/ドーナツ系 6 ブロックの columns 構築は完全に同じ定型である。

```ruby
hash.to_a.slice(0, 10)
  .push(['etc', hash.values.slice(3..-1).try(:sum)])
  .select {|_, v| v.present? }
  .inspect
```

## 重要な発見

### cache_if_production は Pi では常に素通し

`ApplicationController#cache_if_production`（application_controller.rb:25-33）は `Rails.env.production?` のときだけ `Rails.cache.fetch` を通し、それ以外はブロックをそのまま `yield` する。CLAUDE.md の Gotcha 7 のとおり Pi は `RAILS_ENV=development` で動いているため、実運用環境ではキャッシュが一切効いていない。

これは今回の変更に対して二つの帰結を持つ。第一に、後半 4 クエリは現在ダッシュボードを開くたびに全期間を集約している。期間で絞れば処理量は減る方向であり、性能劣化の懸念は小さい。第二に、キャッシュキーの誤りは Pi 上の動作確認では絶対に検出できない。キーに期間を含め忘れても Pi では正しい数字が出るため、コードの読み合わせでしか担保できない。

### 期間を絞ると空データの経路が新たに開く

現状 `_unique_recipient_bounced.html.erb` には `present?` ガードがない。全期間集計であればテーブルに 1 件でもレコードがあれば必ず行が返るため、これまで問題にならなかった。期間で絞ると、狭い範囲や該当バウンスのない addresser で結果が空 Hash になる。

空 Hash を定型に通すと `{}.to_a.slice(0, 10)` が `[]`、`{}.values.slice(3..-1)` が `nil`（サイズ 0 の配列に対する `[3..-1]` は `nil`）、`nil.try(:sum)` が `nil` となり、`present?` フィルタで落ちて最終的に `columns: []` になる。c3 は例外を投げないが、空のチャート枠と `0 recipients` のドーナツタイトルだけが残る。

対して `_bounced_by_type.html.erb` は `@bounced_by_type.sort_by(&:first).each_slice(4)` のループなので、空 Hash なら繰り返し自体が回らず、見出しだけが残る。既存の `if reason.present?`（:11）も chunk の穴を埋めるための nil ガードとして機能している。したがって JS の新規ガードが要るのは `_unique_recipient_bounced` 側だけで、`_bounced_by_type` は空表示の扱いをどうするかの判断に留まる。この判断は plan.md の残決定事項 2 で決着済み（両セクションに `No data in this period.` を出す）。実装時は plan.md を正とする。

### 既存インデックスの状況

`db/schema.rb:39-51` の `bounce_mails` には 13 個のインデックスがある。期間レンジに使えるのは `idx_timestamp`（timestamp 単独）と `idx_timestamp_addresser`（timestamp, addresser）の 2 つ。今回追加する述語は `timestamp` のレンジ + 任意の `addresser` 等値なので、`idx_timestamp_addresser` の先頭カラムでレンジ走査に入る形になる。ただしレンジ条件の後ろに続く `addresser` は複合インデックス内で絞り込みに使えないため、実質 `idx_timestamp` 相当の効き方になる。

GROUP BY 対象は `destination` / `reason` / `addresser_alias`（式）で、いずれもレンジ走査の結果に対するテンポラリテーブル集約になる。`idx_reason_destination` は `@bounced_by_type` の `group(:reason, :destination)` を全件走査でカバーできる可能性があるが、期間述語が入るとオプティマイザは range スキャンを選ぶ公算が高い。

投機的なインデックス追加はしない。CLAUDE.md にあるとおり `20260425000001_cleanup_redundant_performance_indexes` で冗長インデックスを整理した経緯があり、実測なしに増やすのは同じ失敗の繰り返しになる。遅い場合は Pi 上で `monitor_performance.rb` と `EXPLAIN` を先に取る。

### テスト戦略は事実上存在しない

`test/` 配下の実ファイルは `test_helper.rb` と `status_controller_test.rb` の 2 つのみで、他はすべて `.keep`。`fixtures` も空。その `status_controller_test.rb` は `MonitorControllerTest` というクラス名で `monitor_index_url` を叩いているが、`config/routes.rb` に `monitor` ルートは存在せず、実行すれば `NameError` で落ちる。CI にもテストジョブはなく（`bundler-audit` のみ）、走らせている人がいないため放置されている。

加えてローカルには MySQL が無い（CLAUDE.md の Local Environment Constraints）。したがって本タスクの検証は自動テストでは成立せず、Pi 上での実地確認と SQL による突き合わせに依存する。

## 注意点・リスク

タイムゾーンについては、`config/application.rb:22` で `config.active_record.default_timezone = :local` が設定されており、Pi は TZ=Asia/Tokyo で動く。`bounce_mails.timestamp` は precision なしの datetime で、日付境界はローカル時刻で解釈される。今回は述語の中身を変えず scope へ移すだけなので、新しいタイムゾーンの穴は増えない。

期間述語の言い換えが最大の落とし穴である。`>= from AND < to + 1.day` 以外の書き方をすると、上下のチャートの合計が食い違う。scope 化する場合は scope 内でこの式を 1 回だけ定義し、呼び出し側では `to + 1.day` を渡さない（scope が内部で加算する）ようにして、加算漏れ・二重加算を構造的に防ぐ。

キャッシュキーの変更漏れは Pi では観測不能である。前掲のとおりコードレビューでしか担保できない。

`@uniq_count_by_sender` の SELECT エイリアス GROUP BY は、`where` を挟む順序を変えなければそのまま動く。ただし `BounceMail.within_period(...).select(...)` のように scope を先頭に置くと、`select` が後から来るためリレーション構築順が現在（`BounceMail.select(...)` が先）と入れ替わる。ActiveRecord は SQL 生成時に句をまとめるので結果は同じだが、差分レビュー時に見落としやすい箇所として記録しておく。

セクションの意味変化も影響範囲に入る。`_unique_recipient_bounced.html.erb:1` の `uniq_recipient_count` は今後「指定期間内のユニーク受信者数」になる。残決定事項 3 で見出しへの期間表示（案 B）が選ばれているため、文言側で担保する。

`shorten_stats` の存在理由が弱まる点は記録に留める。このフラグは後半 4 クエリが全期間集計で重いことへの緊急回避として入っている。期間で絞れば前提が変わるが、今回はフラグの挙動を変更しない。

## 別件として記録するバグ（今回のスコープ外）

パイ/ドーナツ系 6 ブロックすべてで `etc` の集計対象がずれている。

```ruby
hash.to_a.slice(0, 10)                                  # 上位 10 件を個別表示
  .push(['etc', hash.values.slice(3..-1).try(:sum)])    # 4 件目以降の合計を etc に
```

個別表示は 10 件なのに `etc` は 4 件目以降を合計しているため、4〜10 件目が個別スライスと `etc` の両方に計上され、チャート全体の合計が実際の総数より大きくなる。`slice(0, 10)` と `slice(3..-1)` のどちらが意図だったかは履歴からは判断できない（`10` を導入したコミットが `3` を直し忘れた形に見える）。

該当箇所は `_recent_bounced.html.erb:73-76` と `:91-94`、`_unique_recipient_bounced.html.erb:25-28`・`:43-46`・`:58-61`、`_bounced_by_type.html.erb:25-28` の 6 箇所。

日付範囲とは直交した既存バグであり、修正するとチャートの見た目の数値が変わるため、本タスクとは分けて判断する。今回のスコープには含めない。
