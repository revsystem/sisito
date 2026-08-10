# 検証結果レポート: ダッシュボード全チャートへの日付範囲反映

実施日: 2026-08-10
対象: `heads/stats_date_range_all_charts`（6de78ea / 080c6c2）を Raspberry Pi へ反映し、ユニット A〜D を検証
関連計画: [.claude/docs/plans/2026-08-10-stats-date-range-all-charts-plan.md](../plans/2026-08-10-stats-date-range-all-charts-plan.md)
関連調査: [.claude/docs/research/2026-08-10-stats-date-range-all-charts-research.md](../research/2026-08-10-stats-date-range-all-charts-research.md)

## サマリ

| 項目 | 結果 |
| --- | --- |
| 合否 | 合格。ユニット A〜D の全検証項目が期待どおり |
| 上半分の等価性 | 反映前後で 4 チャートの JS が完全一致（バイト一致） |
| 下半分の期間追従 | 3 チャートすべてが変化。reason 別ドーナツは 15 個 → 4 個 |
| SQL 突き合わせ | destination / sender / bounced_by_type の 3 系統とも一致 |
| 空データ表示 | 例外なく HTTP 200、`No data in this period.` が 2 セクションに出力 |
| addresser 併用 | 期間と addresser の AND 絞り込みが正しく機能 |
| 性能 | 定常状態で反映後 ≈0.11s / 反映前 ≈0.125s。差はノイズ範囲、劣化なし |
| 主要な発見 | Pi の `vendor/bundle` が rails 7.2.3.1 のままで `Gemfile.lock`（7.2.3.2）と不一致。本変更とは無関係の既存問題だが Puma を再起動できない状態 |

## 検証内容

### 環境

Raspberry Pi (`pi@192.168.1.12`)、`RAILS_ENV=development`、Puma 8.0.2 が `tcp://0.0.0.0:1080` で稼働。`bounce_mails` は 1,376,848 行、`timestamp` の範囲は 2022-10-12 〜 2026-08-09。`shorten_stats` は未設定（後半セクションも描画される）。

固定検証期間は `from=2026-08-05&to=2026-08-07` を使用。過去の閉じた 3 日間（各 431 / 406 / 907 件）で、検証中の取り込みによる偽差分が生じない。

### 反映方法

`bin/deploy.sh` は `git pull --ff-only origin master` を行うため未マージブランチには使えない。ブランチを push した上で Pi 側で `git fetch` + `git checkout` する方式を採った。gem もアセットも変更していないため `bundle install` / `assets:precompile` は不要。

`spring stop` は失敗した（後述の副次的発見）。Spring は CLI 用プリローダで、HTTP 経由の検証には影響しないため続行した。Rails development の自動リロード（`config.cache_classes = false`）によりコード変更は Puma 再起動なしに反映され、期間ラベルの出力で反映を確認した。

### A-1 / A-5: 上半分の等価性

反映前後の `/` の HTML から `c3.generate` ブロックを抽出し、`bindto` ごとに空白を正規化して比較した。

```
=== A-5: 上半分4チャートの反映前後比較 ===
  count_by_date: 一致
  count_by_destination: 一致
  count_by_reason: 一致
  count_by_reason_date: 一致
```

反映前の基準値（抜粋）は以下のとおりで、反映後も同一だった。

```
count_by_date  ['x', "2026-08-05","2026-08-06","2026-08-07"], ['bounce mail count', 431,406,907]
count_by_reason  [["userunknown", 1699], ["filtered", 34], ["securityerror", 6], ["mailboxfull", 5], ["etc", 5]]
```

### D-1: 期間ラベル

両セクションの見出しに期間が出力された。

```html
  Unique Recipient Bounced
  <span class="text-muted">2026-08-05 〜 2026-08-07</span>
  <span class="text-muted">(677 recipients)</span>

  Bounced by Type
  <span class="text-muted">2026-08-05 〜 2026-08-07</span>
```

### D-2: 下半分の期間追従

反映前の `uniq_count_by_destination` は docomo.ne.jp が 734 だった。同期間の docomo 宛バウンス総数は 619 であり、734 > 619 から反映前が全期間集計だったことが実データで確認できる。反映後は 255 に変化した。

```
uniq_count_by_destination: 変化あり
uniq_count_by_reason: 変化あり
uniq_count_by_sender: 変化あり

bounced_by_* ドーナツ数  before: 15 個 → after: 4 個
```

ドーナツが 4 個になったことは、同期間の `SELECT COUNT(DISTINCT reason)` が 4 を返すことと一致する。

### D-3: 直接 SQL との突き合わせ

境界は `timestamp >= '2026-08-05' AND timestamp < '2026-08-08'`（`to` 当日を含むため上限は 08-08 00:00）。

`uniq_count_by_destination` は上位 9 件が完全一致した。10 件目のみ画面が `willcom.com, 2`、SQL が `c.vodafone.ne.jp, 2` と異なるが、両者とも値は 2 で、同値のときの並び順が Ruby 側の `sort_by(&:last).reverse` と MySQL の `ORDER BY` で異なるだけである。値の不一致ではない。

```
画面: [["docomo.ne.jp", 255], ["ezweb.ne.jp", 203], ["softbank.ne.jp", 72], ["i.softbank.jp", 60],
       ["t.vodafone.ne.jp", 43], ["disney.ne.jp", 12], ["yahoo.co.jp", 5], ["k.vodafone.ne.jp", 4], ["au.com", 3], ...]
SQL:   docomo.ne.jp 255 / ezweb.ne.jp 203 / softbank.ne.jp 72 / i.softbank.jp 60 /
       t.vodafone.ne.jp 43 / disney.ne.jp 12 / yahoo.co.jp 5 / k.vodafone.ne.jp 4 / au.com 3 / ...
```

`uniq_count_by_sender` は完全一致した（`info@msc-dance.com` 676、`mscworld-bounces+sacchi-smile...` 1）。

`bounced_by_type` も 3 reason すべて一致した。

```
画面 bounced_by_filtered       [["yahoo.co.jp", 15], ["ezweb.ne.jp", 14], ["ybb.ne.jp", 4], ["yahoo.ne.jp", 1], ["etc", 1]]
SQL  filtered                  yahoo.co.jp 15 / ezweb.ne.jp 14 / ybb.ne.jp 4 / yahoo.ne.jp 1
画面 bounced_by_mailboxfull    [["icloud.com", 4], ["softbank.ne.jp", 1]]
SQL  mailboxfull               icloud.com 4 / softbank.ne.jp 1
画面 bounced_by_securityerror  [["u01.gate01.com", 4], ["pm.highway.ne.jp", 2]]
SQL  securityerror             u01.gate01.com 4 / pm.highway.ne.jp 2
```

`bounced_by_filtered` の `etc: 1` は既知の `etc` 二重計上バグによるもので、4 件目の `yahoo.ne.jp, 1` が個別スライスと `etc` の両方に計上されている。計画どおり個別スライスで比較したため検証は成立した。中央の合計で比較していれば 35 対 34 の不一致となり、存在しない境界バグを追うことになっていた。

### D-4: データが無い期間

`from=2020-01-01&to=2020-01-02`（データ最古は 2022-10-12）で確認した。

```
HTTP_STATUS=200
No data in this period 出現数: 2
c3.generate 数: 1
期間ラベル: 2020-01-01 〜 2020-01-02
例外/500の痕跡: 0
```

残った 1 個の `c3.generate` は `count_by_date` で、日付ゼロ埋め（`stats_controller.rb:21`）により常に非空になるため期待どおり。

### D-5: addresser 併用

`addresser=info@msc-dance.com` を指定すると `uniq_count_by_sender` が当該 1 件（676）のみになり、`uniq_count_by_destination` の softbank.ne.jp が 72 → 71 に減った。差分の 1 件はもう一方の addresser 由来で、AND 絞り込みが効いている。

少数側 addresser（`mscworld-bounces+sacchi-smile.142601=softbank.ne.jp@ml.msc-dance.jp`、期間内 1 件）を指定すると、`uniq_count_by_destination` が `[["softbank.ne.jp", 1]]`、ドーナツは `bounced_by_mailboxfull` の 1 個のみとなり、D-3 の SQL（mailboxfull / softbank.ne.jp / 1）と一致した。

### 性能

初回計測で反映前 0.19s・反映後 0.43s と逆転して見えたため、A/B で 3 回ずつ再測定した。

```
branch (期間フィルタあり)  0.113s / 0.109s / 0.109s
master (期間フィルタなし)  0.341s / 0.124s / 0.130s
branch 再測定              0.290s / 0.117s / 0.112s
```

ブランチ切り替え直後の初回リクエストが Rails のコードリロードで 0.3s 前後になり、以降は定常状態に落ち着く。定常状態はブランチ ≈0.11s、master ≈0.125s で、差はノイズ範囲。初回計測の逆転はリロード由来であり、クエリコストではなかった。

## 結果

計画の検証手順 1〜7 はすべて期待どおりに通った。特に、上半分の等価性がバイト一致で確認できたこと、下半分の期間追従が SQL と一致したこと、`etc` 二重計上を織り込んだ比較方法（個別スライスで見る）が実際に機能したことの 3 点は、計画時の想定が実地で裏付けられた形になる。

差分が出た点は 1 つで、`uniq_count_by_destination` の 10 位が画面と SQL で異なった。ただし両者とも値は 2 の同値で、Ruby と MySQL の同値ソートの安定性の違いによるものであり、実装の問題ではない。

計画が「性能は改善方向」と見立てていた点は、実測では「有意な差なし（わずかにブランチが速い）」だった。改善も劣化もしていない。1,376,848 行という規模でも、期間フィルタの有無がレスポンスタイムに現れるほどのボトルネックにはなっていない。

## 副次的発見

Pi の `vendor/bundle` に rails 7.2.3.1 しか入っておらず、`Gemfile.lock` の 7.2.3.2 と食い違っている。`mise exec -- bundle exec spring stop` は `Could not find rails-7.2.3.2 ... in locally installed gems (Bundler::GemNotFound)` で失敗する。原因は CVE-2026-66066 対応（fed20fe、`aa07450` でマージ）以降、Pi で `bin/deploy.sh` が実行されておらず `bundle install` が走っていないこと。本変更とは無関係の既存問題。

稼働中の Puma（PID 2024761）は bundle 更新前に起動しており rails 7.2.3.1 をメモリに保持しているため、現在は正常に応答している。ただしこの状態で Puma を再起動すると同じ `GemNotFound` で起動に失敗する。今回は再起動が不要だったため回避したが、次回のデプロイ時には `bundle install` を先に通す必要がある。

Spring のプロセスが 3 系統残留している（505 時間前 / 311 時間前 / 144 時間前に起動）。CLI 用プリローダであり Puma とは独立しているため今回の検証には影響しなかった。

## 別Issue候補リスト

- Pi の `vendor/bundle` を `Gemfile.lock`（rails 7.2.3.2）に追従させる。`bin/deploy.sh` の実行、または `bundle install` 単体の実行。Puma 再起動が必要になる前に解消しておく必要がある
- `etc` 系列の二重計上バグの修正（6 箇所。research.md 記載）。`slice(0, 10)` で個別表示しながら `etc` に `slice(3..-1)` の合計を入れており、4〜10 件目が重複計上される
- テスト基盤の整備。`sisito_test` データベースの用意、stale な `status_controller_test.rb`（存在しない `monitor_index_url` を参照）の修正、GitHub Actions へのテストジョブ追加

## 追記: master 復帰時に Puma が停止し、bundle 追従で復旧した（2026-08-10）

PR #37 のマージ後、Pi を `heads/stats_date_range_all_charts` から master へ戻して `git pull` したところ、稼働していた Puma（PID 2024761）が停止した。`log/development.log` の最終行は正常な 200 応答で、エラー・例外・OOM の痕跡はなく、screen/tmux セッションも残っていなかったため、停止の直接原因は特定できていない。

問題は、この時点で Puma を起動し直せなかったことである。副次的発見に記したとおり `vendor/bundle` は rails 7.2.3.1 のままで、`Gemfile.lock` の 7.2.3.2 と食い違っていた。稼働中の Puma は更新前に起動して旧 gem をメモリに保持していたため動き続けていたが、一度落ちると同じ構成では二度と起動できない。boot チェックでも `Could not find rails-7.2.3.2 ... (Bundler::GemNotFound)` で失敗した。

`bin/deploy.sh` を実行して bundle を `Gemfile.lock` に追従させ（rails 7.2.3.2 が入り、boot チェックが `boot OK` を返すことを確認）、`nohup` で Puma を起動して復旧した。復旧後の `/?from=2026-08-05&to=2026-08-07` は HTTP 200、期間ラベル・ドーナツ 4 個ともに正常だった。

この一件で、副次的発見に挙げた bundle 不一致は「次回のデプロイ時に対処すべき問題」ではなく「サービス停止に直結する問題」だったことが分かった。同様に、`RAILS_ENV=development` の稼働ホストでプロセスがメモリ上の旧 gem で動き続けている状態は、再起動するまで問題が表面化しない。

## 追記: 過去の期間でもデータは変わりうる（検証手順の前提の訂正）

master 復帰後の再検証で、ブランチ検証時（after）と出力が一致しなかった。原因はコードではなくデータの変化である。

```
総行数        1,376,848 → 1,376,850（+2）
2026-08-05        431 → 433（+2）
増分の内訳    reason=mailboxfull / destination=gmail.com が 2 件
最新 created_at  2026-08-10 14:00:07
```

計画の検証手順 1 は「過去の閉じた期間を使えば、デプロイ中の取り込みによる偽差分を避けられる」という前提で書いていたが、これは誤りだった。`update-sisto-db.rb` はバウンスメール自身の日時を `timestamp` に格納するため、いま実行した取り込みが過去日付の行を挿入しうる。`created_at` は取り込み時刻だが `timestamp` は過去になる。

したがって、反映前後の比較を厳密に行うなら、期間の選び方ではなく「比較の直前直後に取り込みを走らせない」ことで担保するしかない。あるいは `created_at` にも上限を付けた SQL で突き合わせる。今回の A-5（上半分のバイト一致）は取り込みを挟まない短い間隔で実施したため成立していた。

## 残課題・次のアクション

- PR #37 はマージ済み、Issue #36 はクローズ済み。Pi・ローカルとも master（46c3dff）に復帰し、Puma は PID 2039166 で稼働中
- フォローアップの Issue を起票済み。#38（`etc` 二重計上バグ）、#39（テスト基盤の整備）
- Puma の停止原因は未特定のまま。再発した場合に切り分けられるよう、起動方法（nohup か screen/tmux か）と `log/server.log` の残り方を整理しておきたい
- 検証手順の前提の訂正（過去の期間でもデータは変わりうる）は、次に同種の前後比較を行うときに反映する

## 結論

ダッシュボードの全 8 チャートが日付範囲に追従するようになり、計画で定めた検証項目はすべて合格した。上半分の等価性がバイト一致で確認できたため、`BounceMail.within_period` への集約が挙動を変えていないことは実地で確定している。下半分は期間追従が SQL と一致し、空データ・addresser 併用の各経路も期待どおりに動作した。

計画時に「Pi では検証できない」と整理していたキャッシュキーの正しさは、今回も検証できていない。`cache_if_production` が `RAILS_ENV=development` では素通しになるためで、これはコードレビューで担保済みという扱いのまま変わらない。将来 Pi を `RAILS_ENV=production` へ移行する場合は、この 8 キーが最初の確認対象になる。

検証の副産物として、Pi の bundle が `Gemfile.lock` から取り残されている既存問題が判明した。現状は稼働中の Puma がメモリ上の旧 gem で動いているため表面化していないが、再起動すると起動に失敗する。本変更とは独立した問題として、優先的に解消することを勧める。
