# ダッシュボード全チャートへの日付範囲反映 実装計画

日時: 2026-08-10
深度: standard
関連調査: [.claude/docs/research/2026-08-10-stats-date-range-all-charts-research.md](../research/2026-08-10-stats-date-range-all-charts-research.md)
設計仕様: [.claude/docs/specs/2026-08-10-stats-date-range-all-charts-spec.md](../specs/2026-08-10-stats-date-range-all-charts-spec.md)

## 概要

ダッシュボード下半分の 4 集計（Unique Recipient Bounced の 3 チャートと Bounced by Type の reason 別ドーナツ群）に、上半分と同じ日付範囲フィルタを適用する。

期間述語は `BounceMail` の scope に一本化し、既に期間フィルタを持つ上半分 4 ブロックも含めて 8 箇所すべてを scope 経由に置き換える。上下で境界条件がずれると「パイの合計が棒グラフと合わない」というデータバグに見えるため、述語の単一情報源化がこのタスクの中心的な安全策になる。

## アプローチ

spec の残決定事項で確定した 3 点を前提とする。

論点 1 は B（`BounceMail` に scope を定義して 8 箇所すべてで使う）。論点 2 は A（下半分の `expires_in` を 2 時間から 15 分に揃える）。論点 3 は B（セクション見出しに集計期間を明示する）。

scope の定義では `to + 1.day` の加算を scope 内部に閉じ込める。呼び出し側は素の `@recent_days_to` を渡すため、加算漏れや二重加算が構造的に起こり得なくなる。これが「A. 8 箇所に同じ式を書く」を採らない実質的な理由である。

キャッシュキーへの期間追加は必須とする。`cache_if_production` は `Rails.env.production?` 以外でブロックを素通しするため、Pi（`RAILS_ENV=development`）ではキーが古いままでも正しい数字が表示され、この漏れは動作確認では検出できない。コードの読み合わせで担保する。

採用しなかった案として、コントローラに private メソッド（`scoped_relation`）を置いて addresser 絞り込みごと集約する案（spec 論点 1-C）がある。`relation = ...; relation = relation.where(addresser:) if ...` の定型 8 回分も消えるが、`@uniq_count_by_sender` と `@count_by_reason_date` は先頭が `select(...)` で形が異なり、統一のために各ブロックへ追加の調整が要る。今回は述語のずれを防ぐ目的に絞り、scope 化に留める。

## 変更内容

### 変更1: 期間 scope の定義

対象: `app/models/bounce_mail.rb`

クラス先頭に scope を追加する。`to` を含む日の 23:59:59 までを対象にするため、内部で 1 日加算した上限との `<` 比較にする。既存 `stats_controller.rb:10` の述語と完全に同一の SQL になる。

```ruby
class BounceMail < ApplicationRecord
  # timestamp が from 〜 to（to 当日を含む）に入るレコードに絞る。
  # from / to はカレンダー日（Date）を渡す。時刻付きオブジェクトを渡すと
  # 「その時刻 + 1 日」が上限になり、当日を丸ごと含める意図からずれる。
  # 上限の +1.day は呼び出し側に書かせず、境界のずれを構造的に防ぐ。
  scope :within_period, ->(from, to) {
    where('timestamp >= ? AND timestamp < ?', from, to + 1.day)
  }

  def mask_recipient
```

引数を `to.to_date` で防御的に丸める案もあるが採らない。現在の供給源は `stats_controller.rb:3-5` の `params[:to].to_date` と `Date.today` の 2 つだけで、いずれも `Date` である。使われていない経路のために暗黙の型変換を入れると、将来 `Time` を渡した人が「切り捨てられたことに気づかない」失敗に変わる。契約はコメントで示し、破った場合は意図どおりの値にならないことで顕在化させる。

### 変更2: 上半分 4 ブロックの scope 置き換え（挙動不変）

対象: `app/controllers/stats_controller.rb`

同一の述語・同一の句構成を保つ機械的な置換。`@count_by_date`（:10）、`@count_by_destination`（:25）、`@count_by_reason`（:34）、`@count_by_reason_date`（:44）の 4 箇所。

ローカルに DB が無く `to_sql` で生成 SQL を突き合わせられないため、等価性は「同じ述語・同じ句が揃っている」ことの読み合わせと、後述の検証手順（固定期間での前後比較）で担保する。

```ruby
# 変更前（:10 / :25 / :34 に同一の式）
relation = BounceMail.where('timestamp >= ? AND timestamp < ?', @recent_days_from, @recent_days_to + 1.day)

# 変更後
relation = BounceMail.within_period(@recent_days_from, @recent_days_to)
```

`@count_by_reason_date`（:43-44）は `select` が先頭に来る形なので、チェーンの末尾を置き換える。

```ruby
# 変更前
relation = BounceMail.select(:reason, Arel.sql("DATE(timestamp) AS date"), Arel.sql("COUNT(reason) AS count_reason"))
                     .where('timestamp >= ? AND timestamp < ?', @recent_days_from, @recent_days_to + 1.day)

# 変更後
relation = BounceMail.select(:reason, Arel.sql("DATE(timestamp) AS date"), Arel.sql("COUNT(reason) AS count_reason"))
                     .within_period(@recent_days_from, @recent_days_to)
```

### 変更3: 下半分 4 ブロックへの期間フィルタ適用

対象: `app/controllers/stats_controller.rb`

各ブロックで、キャッシュキーへの期間追加、`expires_in` の 15 分への変更、`within_period` の適用の 3 点を同時に行う。

```ruby
# 変更前（:61）
@uniq_count_by_destination = cache_if_production("uniq_count_by_destination_#{@addresser}", expires_in: 2.hours) do
  relation = BounceMail

  relation = relation.where(addresser: @addresser) if @addresser.present?

  relation.distinct.group(:destination).count(:recipient)
          .sort_by(&:last).reverse.to_h
end

# 変更後
@uniq_count_by_destination = cache_if_production("uniq_count_by_destination_#{@recent_days_from}_#{@recent_days_to}_#{@addresser}", expires_in: 15.minutes) do
  relation = BounceMail.within_period(@recent_days_from, @recent_days_to)

  relation = relation.where(addresser: @addresser) if @addresser.present?

  relation.distinct.group(:destination).count(:recipient)
          .sort_by(&:last).reverse.to_h
end
```

`@uniq_count_by_reason`（:70）も同型。

```ruby
@uniq_count_by_reason = cache_if_production("uniq_count_by_reason_#{@recent_days_from}_#{@recent_days_to}_#{@addresser}", expires_in: 15.minutes) do
  relation = BounceMail.within_period(@recent_days_from, @recent_days_to)

  relation = relation.where(addresser: @addresser) if @addresser.present?

  # オリジナルのシンプルな実装（MySQL設定改善により高速化）
  relation.distinct.group(:reason).count(:recipient)
          .sort_by(&:last).reverse.to_h
end
```

`@uniq_count_by_sender`（:80）は `select` が先頭に来るため、チェーン末尾に付ける。SELECT エイリアスを GROUP BY する構造（`group(Arel.sql('addresser_alias'))`）は変えない。

```ruby
@uniq_count_by_sender = cache_if_production("uniq_count_by_sender_#{@recent_days_from}_#{@recent_days_to}_#{@addresser}", expires_in: 15.minutes) do

  select_columns = <<-SQL
    COUNT(DISTINCT recipient) AS count_recipient,
    CASE
    WHEN addresseralias = '' THEN addresser
    ELSE addresseralias
    END AS addresser_alias
  SQL

  relation = BounceMail.select(Arel.sql(select_columns))
                       .within_period(@recent_days_from, @recent_days_to)

  relation = relation.where(addresser: @addresser) if @addresser.present?

  relation.group(Arel.sql('addresser_alias'))
          .map {|r| [r.addresser_alias, r.count_recipient] }
          .sort_by(&:last).reverse.to_h
end
```

`@bounced_by_type`（:100）も同型。

```ruby
@bounced_by_type = cache_if_production("bounced_by_type_#{@recent_days_from}_#{@recent_days_to}_#{@addresser}", expires_in: 15.minutes) do

  count_by_reason_destination = {}

  relation = BounceMail.within_period(@recent_days_from, @recent_days_to)

  relation = relation.where(addresser: @addresser) if @addresser.present?

  relation.group(:reason, :destination).count.each do |(reason, destination), count|
    count_by_reason_destination[reason] ||= {}
    count_by_reason_destination[reason][destination] = count
  end

  count_by_reason_destination
end
```

### 変更4: 期間ラベルのヘルパー

対象: `app/helpers/stats_helper.rb`（現在は空モジュール）

見出しに添える期間表記を 1 箇所で定義する。書式は残決定事項 1 の回答 A に従い、`2026-07-27 〜 2026-08-10` の形とする。

```ruby
module StatsHelper
  # セクション見出しに添える集計期間の表記。
  # Recently Bounced は直下のフォームに from/to が出ているため対象外。
  def stats_period_label(from, to)
    "#{from.strftime('%Y-%m-%d')} 〜 #{to.strftime('%Y-%m-%d')}"
  end
end
```

### 変更5: Unique Recipient Bounced の見出しとガード

対象: `app/views/stats/_unique_recipient_bounced.html.erb`

見出しに期間を添える。`(N recipients)` が期間内の数であることを読み取れるようにする。

```erb
<div class="page-header">
  <span class="glyphicon glyphicon-stats"></span>
  Unique Recipient Bounced
  <span class="text-muted"><%= stats_period_label(@recent_days_from, @recent_days_to) %></span>
  <span class="text-muted">(<%= uniq_recipient_count %> recipients)</span>
</div>
```

3 つの `c3.generate` ブロックを `present?` でガードする。期間を絞ると結果が空 Hash になり得るようになり、そのまま通すと `columns: []` の空チャートが描画されるため。`_recent_bounced.html.erb:66` と同じ書き方に揃える。

```erb
<% if @uniq_count_by_destination.present? %>
  <%= javascript_tag do %>
    c3.generate({
      bindto: '#uniq_count_by_destination',
      ...
    });
  <% end %>
<% end %>
```

`@uniq_count_by_reason` と `@uniq_count_by_sender` も同様に囲む。`<div id="...">` の器は残す（`_recent_bounced` もガード対象は JS のみで器は常に出している）。

残決定事項 2 の回答 B に従い、3 チャートすべてが空のときだけ空表示のメッセージを出す。`@uniq_count_by_destination` 単体で判定すると、一部だけ描画されている状態で「No data」が同時に出てしまう。挿入位置は見出しの直後、`<section>` の前。

```erb
<% if @uniq_count_by_destination.blank? && @uniq_count_by_reason.blank? && @uniq_count_by_sender.blank? %>
  <p class="text-muted">No data in this period.</p>
<% end %>
```

### 変更6: Bounced by Type の見出しと空表示

対象: `app/views/stats/_bounced_by_type.html.erb`

見出しに期間を添える。チャート生成側は `each_slice` のループなので、空 Hash なら繰り返しが回らず JS のガードは不要（research.md で確認済み）。ただし空のときに見出しだけが宙に浮くため、残決定事項 2 の回答 B に従って空表示のメッセージを出す。こちらは判定対象が 1 つしかない。

挿入位置は `each_slice` ループの外、見出しの直後。ループの内側に入れると reason ごとに繰り返し出力される。

```erb
<div class="page-header">
  <span class="glyphicon glyphicon-stats"></span>
  Bounced by Type
  <span class="text-muted"><%= stats_period_label(@recent_days_from, @recent_days_to) %></span>
</div>

<% if @bounced_by_type.blank? %>
  <p class="text-muted">No data in this period.</p>
<% end %>
```

## 影響範囲

既存テストへの影響はない。`test/` の実ファイルは `test_helper.rb` と `status_controller_test.rb` の 2 つだけで、後者は存在しない `monitor_index_url` を参照しており実行すれば落ちる。GitHub Actions にもテストジョブはなく（`bundler-audit` のみ）、今回の変更で新たに壊れるものはない。

新規テストは追加しない。グローバル CLAUDE.md は TDD を優先すると定めているが、このプロジェクトはローカルに MySQL が無く、`config/database.yml` の test ブロックが指す `sisito_test` の Pi 上での疎通も未確認で、CI にテストジョブも無い。テストを足すには、その足場作り（Pi またはCI への MySQL 用意、fixtures 整備、stale テストの修正）が本タスクより大きくなる。テスト基盤の整備は日付範囲対応とは独立に進められるため、別 Issue として切り出す。`within_period` の境界条件は下記の検証手順で確認する。

API 変更なし。`/status` は別コントローラで、今回触らない。ルーティングにも変更はない。

マイグレーションなし。スキーマもインデックスも変更しない。

外部から見た挙動の変更は 2 点ある。第一に Unique Recipient Bounced と Bounced by Type の数値が全期間集計から期間集計に変わる。既定表示（直近 14 日）でも数字が下がるため、見た目上は「値が減った」ように見える。これは意図した変更である。第二に、期間内に該当バウンスがない reason は Bounced by Type のドーナツごと消える。

キャッシュについては、キー文字列が変わるため既存のキャッシュエントリは参照されなくなる。本番相当環境では旧エントリが `expires_in` 経過まで残るがメモリ上の無駄に留まり、明示的な `Rails.cache.clear` は不要。Pi はキャッシュ無効なので影響なし。

## 考慮事項

性能は改善方向と見込む。Pi では `cache_if_production` が素通しのため、下半分 4 クエリは現在ダッシュボードを開くたびにテーブル全体を集約している。期間で絞ればスキャン量は減る。ただし推測であり、遅い場合のみ Pi 上で `monitor_performance.rb` と `EXPLAIN` を取ってから対処する。投機的なインデックス追加はしない（`20260425000001` で冗長インデックスを整理した経緯があるため、実測なしに増やさない）。

`expires_in` を 2 時間から 15 分に下げることで、本番相当環境ではこれら 4 クエリの実行頻度が最大 8 倍になる。Pi はキャッシュ無効なので現状より頻度が増えることはない。将来 `RAILS_ENV=production` へ移行した場合は、この点を再評価する。

セキュリティ上の新規懸念はない。期間は既に `params[:from].to_date` / `params[:to].to_date` を通しており、追加する述語もバインド変数経由である。scope に切り出しても文字列連結は発生しない。

後方互換性について、`from > to` を指定した場合は全チャートが空になる。これは上半分で既に存在する挙動で、今回それが下半分にも波及する。バリデーションの追加は本タスクのスコープ外とする。

`shorten_stats` フラグは挙動を変えない。期間で絞れば「重いから飛ばす」という導入理由は弱まるが、今回は据え置く。

`etc` 系列の二重計上（`slice(0, 10)` で個別表示しながら `etc` に `slice(3..-1)` の合計を入れており 4〜10 件目が重複計上される）は 6 箇所すべてに存在する既存バグだが、日付範囲とは直交するため本計画には含めない。research.md に記録済み。

## 残決定事項（判断ポイント）

### 論点1: 期間ラベルの書式と適用範囲

spec 論点 3 で「見出しに期間を添える」方針は確定したが、具体的な書式と適用先は未確定。Unique Recipient Bounced の見出しには既に `(N recipients)` があり、括弧が二重になる置き方は避けたい。

- A. 見出しの後ろにミュートテキストで期間だけを置き、既存の `(N recipients)` はそのまま残す — 表示例: `Unique Recipient Bounced 2026-07-27 〜 2026-08-10 (37 recipients)` / 利点: 既存要素を触らず、Bounced by Type にも同じ形をそのまま展開できる / 欠点: 情報が横に伸び、狭い画面で折り返す
- B. 括弧内にまとめる — 表示例: `Unique Recipient Bounced (2026-07-27 〜 2026-08-10, 37 recipients)` / 利点: 1 つの補足として読める / 欠点: Bounced by Type 側には `(N recipients)` が無いため、2 セクションで括弧の中身の構造が揃わない
- C. 期間は見出しに出さず、ページ上部（フォームの直下）に「集計期間: 2026-07-27 〜 2026-08-10」を 1 行だけ置く — 利点: 全セクションに一度で効き、見出しが伸びない / 欠点: 下までスクロールすると期間表記が視界から外れる
- D. その他（自由記述）

推奨: A。Bounced by Type と Unique Recipient Bounced で同一の書き方を使え、ヘルパー 1 つで両方に展開できるため。

[Answer]: A

### 論点2: 期間内にデータが無いときのセクション表示

期間を絞ると、これまで起こり得なかった「セクションの中身が空」という状態が発生する。Unique Recipient Bounced は見出しに `(0 recipients)` が出て中身が空、Bounced by Type は見出しだけが残る。

- A. 追加表示はしない。チャートを描かないだけに留める — 利点: 差分が最小。Unique 側は `(0 recipients)` で状態が読める / 欠点: Bounced by Type は見出しだけが宙に浮き、壊れているのか空なのか判別しづらい
- B. データが空のセクションに `No data in this period.` のミュートテキストを 1 行出す — 利点: 空であることが明示され、両セクションで挙動が揃う / 欠点: 表示文言が増え、既存パーシャルに条件分岐が 2 箇所増える
- C. データが空のセクションは見出しごと非表示にする — 利点: 画面がすっきりする / 欠点: セクションが消えると「設定で無効化されたのか」と `shorten_stats` の挙動と紛らわしい
- D. その他（自由記述）

推奨: B。空と故障を利用者が区別できることを優先する。追加は各パーシャル 1 行ずつで済む。

なお B を選ぶ場合、Unique Recipient Bounced 側の条件は 3 つのハッシュすべてが空のときに限る（`@uniq_count_by_destination.blank? && @uniq_count_by_reason.blank? && @uniq_count_by_sender.blank?`）。destination だけを見ると、3 チャートのうち一部だけ描画される状態で「No data」が同時に出てしまう。

[Answer]: B

## 検証方法

自動テストによる検証は成立しない。以下は Pi 上での実地検証を前提とする。

デプロイは `.claude/skills/sisito-deploy` スキルの手順に従う。Pi は Spring を使うため、反映後に `spring stop` を実行しないと旧コードが残る（CLAUDE.md の Gotcha 9）。

確認手順は次のとおり。

1. 変更を反映する前に、固定の期間で `/` を開き、Recently Bounced の 4 チャートの数値を控える。反映後に同じ URL を開き、上半分が完全に一致することを確認する。ここがずれていたら scope 置き換えが等価でない。期間は必ず過去の閉じた範囲（例: `?from=2026-08-01&to=2026-08-02`）を使う。`to` を今日にすると、デプロイ作業中に取り込みが走った場合に件数が増え、等価性の崩れと区別がつかなくなる
2. `/` を既定表示（直近 14 日）で開き、Unique Recipient Bounced と Bounced by Type が描画されることを確認する
3. 両セクションの見出しに集計期間（`2026-07-27 〜 2026-08-10` 形式）が表示されることを確認する。フォームで期間を変えたときに見出しの表記も追従することを見る
4. from / to を 1 日だけの範囲に絞って Go を押し、下半分の数値が変わることを確認する。変わらなければ scope が効いていない
5. 下半分の 3 系統について、同じ期間の直接クエリと突き合わせる

```sql
-- uniq_count_by_destination（ドーナツ）
SELECT destination, COUNT(DISTINCT recipient)
FROM bounce_mails
WHERE timestamp >= '2026-08-01' AND timestamp < '2026-08-03'
GROUP BY destination ORDER BY 2 DESC;

-- uniq_count_by_sender（パイ）: select 先行のチェーンで構造が他と異なるため個別に確認する
SELECT CASE WHEN addresseralias = '' THEN addresser ELSE addresseralias END AS addresser_alias,
       COUNT(DISTINCT recipient)
FROM bounce_mails
WHERE timestamp >= '2026-08-01' AND timestamp < '2026-08-03'
GROUP BY addresser_alias ORDER BY 2 DESC;

-- bounced_by_type（reason 別ドーナツ）: 戻り値の形が他と異なるため個別に確認する
SELECT reason, destination, COUNT(*)
FROM bounce_mails
WHERE timestamp >= '2026-08-01' AND timestamp < '2026-08-03'
GROUP BY reason, destination ORDER BY 1, 3 DESC;
```

`uniq_count_by_reason` は `uniq_count_by_destination` とチェーンの形が完全に同一（`within_period` → `distinct.group(...).count(:recipient)`）なので、個別の突き合わせは省いてよい。片方が合っていればもう片方も合う。

比較対象はドーナツ／パイの個別スライスの値であり、中央の合計ではない。合計は既知の `etc` 二重計上バグ（research.md 記載）で実数より大きく出るため、合計で突き合わせると正しい実装でも不一致になり、存在しない境界バグを追うことになる。上記の期間は `from=2026-08-01&to=2026-08-02` で開いた画面と一致するはずである（`to` 当日を含むため上限は 08-03 00:00）。ここがずれていたら `within_period` の `+1.day` の扱いを見直す。

6. バウンスが 1 件も無い期間（例: `from=2020-01-01&to=2020-01-02`）を指定し、例外にならず、両セクションに `No data in this period.` が 1 行ずつ出ることを確認する
7. addresser を選択した状態でも 4〜6 が成立することを確認する

キャッシュキーの正しさは Pi では検証できない（`cache_if_production` が素通しのため）。差分レビューで以下 8 個のキーすべてに `#{@recent_days_from}_#{@recent_days_to}` が入っていることを 1 つずつ確認する。

- [ ] `count_by_date_...`
- [ ] `count_by_destination_...`
- [ ] `count_by_reason_...`
- [ ] `count_by_date_reason_...`（変数名は `@count_by_reason_date` だがキーは語順が逆。既存のまま変えない）
- [ ] `uniq_count_by_destination_...`
- [ ] `uniq_count_by_reason_...`
- [ ] `uniq_count_by_sender_...`
- [ ] `bounced_by_type_...`

上 4 つは変更前から期間が入っているため確認のみ。下 4 つが今回の追加対象。

## タスクリスト

大区分は独立実装可能な「ユニット」でまとめる。ユニット A → B → C は順序依存があり並列不可。ユニット内のタスクは上から順に実施する。

### ユニットA: 期間 scope の導入と上半分の置き換え（並列不可: 依存 = なし。ただし B / C の前提）

挙動を変えない置き換えのユニット。ここだけで一度検証を通し、等価性を確定させてから B に進む。B と混ぜると、下半分の数値変化に紛れて上半分の非等価に気づけなくなる。

- [ ] A-1: 反映前の基準値を採取する。Pi で過去の閉じた期間（例: `?from=2026-08-01&to=2026-08-02`）の `/` を開き、Recently Bounced の 4 チャートの数値を記録する
- [x] A-2: `app/models/bounce_mail.rb` に `scope :within_period` を追加する（変更1。引数がカレンダー日である契約をコメントに書く）
- [x] A-3: `stats_controller.rb` の `@count_by_date`・`@count_by_destination`・`@count_by_reason` の 3 箇所を `BounceMail.within_period(@recent_days_from, @recent_days_to)` に置き換える（変更2）
- [x] A-4: `@count_by_reason_date` の `select(...).where(...)` を `select(...).within_period(...)` に置き換える（変更2）
- [ ] A-5: Pi に反映して `spring stop` を実行し、A-1 と同じ URL で 4 チャートの数値が完全に一致することを確認する（検証手順 1）

### ユニットB: 下半分 4 ブロックへの期間フィルタ適用（並列不可: 依存 = ユニットA）

- [x] B-1: `@uniq_count_by_destination` にキャッシュキーの期間追加・`expires_in: 15.minutes`・`within_period` の 3 点を適用する（変更3）
- [x] B-2: `@uniq_count_by_reason` に同じ 3 点を適用する（変更3）
- [x] B-3: `@uniq_count_by_sender` に同じ 3 点を適用する。`select` 先行のチェーン末尾に `within_period` を置き、`group(Arel.sql('addresser_alias'))` は変えない（変更3）
- [x] B-4: `@bounced_by_type` に同じ 3 点を適用する（変更3）
- [x] B-5: 差分レビューで 8 個のキャッシュキーすべてに期間が入っていることをチェックリストで確認する（検証手順末尾。Pi では検証できないためここが唯一の関門）

### ユニットC: ビュー表示（並列不可: 依存 = ユニットB。C-2 と C-3 は相互に並列可）

C-1（ヘルパー）だけは先に必要。C-2 と C-3 は別ファイルで互いに依存しないため、subagent へ分けて同時に進めてよい。

- [x] C-1: `app/helpers/stats_helper.rb` に `stats_period_label(from, to)` を追加する（変更4）
- [x] C-2: `_unique_recipient_bounced.html.erb` の見出しに期間ラベルを添え、3 つの `c3.generate` を `present?` でガードし、3 ハッシュすべてが空のときの `No data in this period.` を見出し直後に追加する（変更5）
- [x] C-3: `_bounced_by_type.html.erb` の見出しに期間ラベルを添え、`@bounced_by_type.blank?` のときの `No data in this period.` を見出し直後（`each_slice` ループの外）に追加する（変更6）

### ユニットD: Pi での検証（並列不可: 依存 = ユニットC）

- [ ] D-0: ユニット B・C の変更を Pi に反映し、`spring stop` を実行する。これを飛ばすと D-1 以降が旧プロセスで走り、変更が反映されていないのに「動いていない」と誤診する（CLAUDE.md の Gotcha 9）
- [ ] D-1: 既定表示で両セクションが描画され、見出しに期間が出ることを確認する（検証手順 2・3）
- [ ] D-2: 1 日だけの範囲に絞り、下半分の数値が変わることを確認する（検証手順 4）
- [ ] D-3: destination / sender / bounced_by_type の 3 系統を同期間の直接 SQL と突き合わせる。比較対象は個別スライスで、中央の合計ではない（検証手順 5）
- [ ] D-4: バウンスの無い期間で例外にならず、両セクションに `No data in this period.` が出ることを確認する（検証手順 6）
- [ ] D-5: addresser を選択した状態で D-2〜D-4 が成立することを確認する（検証手順 7）

### 別 Issue として切り出すもの（本タスクでは実施しない）

- [ ] `etc` 系列の二重計上バグの修正（6 箇所。research.md 記載）
- [ ] テスト基盤の整備（`sisito_test` の用意、stale な `status_controller_test.rb` の修正、CI へのテストジョブ追加）
