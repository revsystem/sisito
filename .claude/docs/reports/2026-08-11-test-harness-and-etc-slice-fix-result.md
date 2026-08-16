# 検証結果レポート: テスト基盤の整備と etc 二重計上の修正

実施日: 2026-08-16
対象: `heads/test_harness_and_etc_slice_fix`（PR #42）のユニットA・B・Cを実装し、GitHub Actions で検証
関連計画: [.claude/docs/plans/2026-08-11-test-harness-and-etc-slice-fix-plan.md](../plans/2026-08-11-test-harness-and-etc-slice-fix-plan.md)
関連調査: [.claude/docs/research/2026-08-11-test-harness-and-etc-slice-fix-research.md](../research/2026-08-11-test-harness-and-etc-slice-fix-research.md)

## サマリ

| 項目 | 結果 |
| --- | --- |
| 合否 | 合格。全ユニット完了、CI 2回とも成功 |
| ユニットA・B（test基盤） | CI 1回目: 5 runs, 9 assertions, 0 failures |
| ユニットC（etc修正） | CI 2回目: 13 runs, 29 assertions, 0 failures |
| レビュー体制 | Cursor Agent（CLI・Herdrスペース両方）で全ユニットを収束確認 |
| 主要な発見 | fixtures の日時が CI ランナーの `TZ` に依存して意味が変わる問題を Plan フェーズで発見・対策済み。CI実行で対策の有効性を実証 |

## 検証内容

### 実装したユニット

ユニットA（`config/environments/test.rb` の `show_exceptions` 修正、`test/fixtures/bounce_mails.yml`、`test/models/bounce_mail_test.rb`、`test/controllers/status_controller_test.rb` の修正）とユニットB（`.github/workflows/test.yml`）は個別にローカル検証・Cursor Agentレビューを経てコミット (`6d9b0a0`, `3e2f0c9`)。ユニットC（`app/helpers/stats_helper.rb` の `chart_columns`、6箇所のビュー置き換え、`test/helpers/stats_helper_test.rb`、`test/controllers/stats_controller_test.rb`）も同様にコミット (`0280d29`)。

### レビュー体制

このセッションでは2種類の Cursor Agent を使い分けた。ユニットA以前（spec/research/plan フェーズ）は `cursor-agent --print --mode ask` の CLI 単発呼び出し。ユニットA・B・C の実装レビューは、herdrスペース内で稼働中の対話型 Cursor Agent（`herdr agent prompt` / `herdr agent wait` 経由）に切り替えた。後者は実際に `gh run view --log` で既存 `bundler-audit` の実行ログを確認する、`chart_columns` を実際に `mise exec -- ruby` でシミュレーション実行する、独自の to-do リストを立てて観点ごとに検証するなど、より踏み込んだ検証を行った。全3ユニットで「収束、承認してよい」の判定を得た。

### 1回目のCI実行（PR #42、ユニットA・Bのみ）

```
Run options: --seed 58677
# Running:
.....
Finished in 0.155635s, 32.1264 runs/s, 57.8275 assertions/s.
5 runs, 9 assertions, 0 failures, 0 errors, 0 skips
```

`test` ジョブは45秒で完走。以下3点が Plan フェーズでの一次資料（activerecordソース読解）に基づく予測どおりであることが実行結果で裏付けられた。

- `db:schema:load` だけで `maintain_test_schema!` の `PendingMigrationError` が発生しない
- `DATABASE_URL=mysql2://root@127.0.0.1:3306/sisito_test` により `host: localhost` のソケット優先解決問題を回避できた
- `TZ: UTC` 設定下で `within_period` の境界条件テスト4件が全て成功し、fixtures の日時が意図どおり格納された

### 2回目のCI実行（PR #42、ユニットC込み）

```
Run options: --seed 4044
# Running:
...
Finished in 0.959987s, 13.5419 runs/s, 30.2087 assertions/s.
13 runs, 29 assertions, 0 failures, 0 errors, 0 skips
```

`stats#index` の統合テストがレイアウト経由でアセットパイプライン（Sprockets + dartsass-sprockets）を要求する点を plan.md で「初回赤くなりうる箇所」として挙げていたが、実際には `Sass @import rules are deprecated`（既知の非ブロッキング警告）が出るのみで問題なく完走した。`bundler-audit` ワークフローも引き続き成功。

### ローカルでの事前検証（CI実行前）

MySQL が無いため `bin/rails test` そのものは実行できず、以下で代替した。

- `mise exec -- ruby -c` による全新規・変更 Ruby ファイルの構文チェック
- 独自のERB構文チェッカー（`javascript_tag do` ブロックを一時的に `<%` に変換してErubiでコンパイルし `RubyVM::InstructionSequence.compile` で検証、`<% end %>` を1つ削った版で確実に検出することも確認）による3ビューファイルの検証
- `TZ=UTC mise exec -- ruby` で fixtures YAML を実際にパースし、4レコードの `timestamp` が意図どおり1秒のずれもなく格納されることを確認
- `chart_columns` のロジックを素のRubyでシミュレーションし、#36検証時に実際にPiで観測した境界データ（`bounced_by_mailboxfull` 3件）で `etc: 0` が混入しないこと、10件超のデータで合計が実件数と一致することを確認

## 結果

期待どおりだった点は、Plan フェーズで見つけた3つの技術的リスク（`maintain_test_schema!`、`DATABASE_URL`、`TZ`依存）が、いずれもCI実行で実証されたことである。特に `TZ` の問題はローカルの推測だけでは気づけず、Plan フェーズで別プロセスによる実測（`TZ=UTC`/`Asia/Tokyo`/`America/Los_Angeles`）まで行って初めて発見できたもので、対策（`TZ: UTC` の明示）が正しく効いたことを境界条件テスト4件の成功で確認できた。

差分は無し。2回とも一発で成功しており、CIが初めて赤くなる可能性を懸念していた箇所（DB接続、アセットパイプライン）はいずれも問題にならなかった。

## 副次的発見

Rails fixtures には `DEFAULTS`（大文字）という予約キー名があり、`ActiveRecord::FixtureSet` がこれを無条件に無視することを Plan フェーズで発見した。当初は「実在するレコード名をYAMLアンカーにする」という代替策を採る予定だったが、こちらの方が Rails 標準の書き方であるため採用した。今後 sisito で fixtures を追加するときは、この `DEFAULTS: &DEFAULTS` パターンを踏襲するとよい。

Herdrスペース内の対話型 Cursor Agent（`w9:p2`）は、以前 PR #35（CVE対応）のレビューにも使われた実績があり、コンテキストを保持したまま複数ユニットのレビューを連続してこなせた。CLI単発呼び出しより検証が踏み込んでいた（実際のCI実行ログの確認、コードの実行シミュレーションなど）。

## 別Issue候補リスト

無し。今回の変更で新たに見つかった、切り出すべき独立した課題はない。

## 残課題・次のアクション

- PR #42 は現在ドラフト状態。全ユニット完了・CI成功を確認したため、レビュー依頼可能な状態にする（`gh pr ready`）かどうかはユーザーの判断
- マージ後、Issue #38・#39 のクローズを確認する
- Pi へのデプロイは本タスクのスコープ外（テスト基盤とチャート表示ロジックの変更であり、#36のような実データ検証は不要と判断。ただしマージ後、Pi上での見た目の変化（チャート個別表示が10件→3件に減る）は運用者への周知が必要）

## 結論

3ユニットすべてが実装・検証・承認のゲートを通過し、GitHub Actions上で2回とも一発成功した。テスト基盤が初めて機能する状態になり（stale だった唯一のテストが直り、CIで実際に走るようになった）、その基盤の上で `etc` 二重計上バグを回帰テスト付きで修正できた。Plan フェーズで発見した `TZ` 依存というfixtures設計上の罠は、対策なしに進んでいれば CI が原因不明に間欠的に失敗する（あるいはCIランナーの既定TZがたまたまUTCである限り気づかれない）類の問題であり、実装前に発見・検証できたことがこのセッションの主要な収穫である。
