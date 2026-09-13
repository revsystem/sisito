# Rails 7.2 → 8.1 アップグレード 実装計画

日時: 2026-09-13
深度: comprehensive
関連調査:
- [.claude/docs/specs/2026-09-13-rails-8-upgrade-spec.md](../specs/2026-09-13-rails-8-upgrade-spec.md)
- [.claude/docs/research/2026-09-13-rails-8-upgrade-research.md](../research/2026-09-13-rails-8-upgrade-research.md)
- [.claude/docs/research/2026-09-13-rails-8-gem-compat-survey.md](../research/2026-09-13-rails-8-gem-compat-survey.md)

## 概要

Rails 7.2.3.2 を 8.1 系へ、`config.load_defaults` を `7.0 → 7.1 → 7.2 → 8.0 → 8.1` の順に1段階ずつ引き上げる。gem バンプは `load_defaults 7.2` 到達後・`8.0` 引き上げ前に行う（rails 7.2 gem が `load_defaults "8.0"` を受け付けないため）。ステージング環境が無い一本道の Pi 本番のみが検証環境のため、7つの小さな PR に分割し、各 PR ごとに Pi 上で起動・主要経路確認を行ってから次に進む。

## アプローチ

- Rails 標準の段階的アップグレード手順（`load_defaults` を1段ずつ上げる）に厳密に従う。一括切り替えは採らない。
- `new_framework_defaults.rb` の削除は独立 PR とし、gem バンプ PR より前にマージする（`to_time_preserves_timezone` が 8.0 で deprecation 警告を出すため）。
- コードベースの grep 済み事前確認: Rails 8.0 で削除される API（`config.read_encrypted_secrets`, `allow_deprecated_parameters_hash_equality`, `allow_deprecated_singular_associations_name`, `use_big_decimal_serializer`, `ProxyObject`, 旧記法 `enum`, `form_with` への `nil` モデル）はいずれもアプリ内で未使用（`grep -rn` で確認済み、ヒット無し）。したがって Rails 8.0 の破壊的変更に対するコード修正は不要で、今回の変更は config ファイルと Gemfile のみに閉じる。
- 代替案として「7.2→8.1を一度に切り替え、`app:update` の差分を丸ごと受け入れる」も検討したが、ステージング無し環境でどの変更が問題を起こしたか切り分けられなくなるため採らない（spec の前提通り）。

## 変更内容（PRを実行順に並べたユニット）

### 共通の Pi 検証手順（Unit 1・2・3・6・7 で共通）

`w9:p2` レビューで指摘・修正: `config.load_defaults` の変更は起動時にしか評価されないため、Puma を再起動しない限り Pi は旧設定のまま動き続ける。「再起動不要」という判断は誤りだった。各 Unit の Pi 検証は次の手順で統一する。

1. CI（`.github/workflows/test.yml`）が green であることを確認
2. Pi 上で `spring stop`（Spring が旧 gem/設定をプリロードしたままだと `bin/rails runner` が新しい状態を反映しない、CLAUDE.md Gotcha 9）
3. `RAILS_ENV=development bin/rails runner 'puts "boot ok"'` で起動確認
4. `bin/deploy.sh` を実行して Puma を再起動する（`server.pid` が生きていれば `mise exec -- bundle exec rails restart` が自動実行される、`bin/deploy.sh` L51-53）。デプロイ手順・事前/事後チェックの詳細は `.claude/skills/sisito-deploy` を参照
5. `/`, `/bounce_mails`, `/whitelist_mails`, `/admin`, `/sender`, `/status` を手動で一巡

### Unit 1: `load_defaults` を `application.rb` に一本化（`7.0`）

対象: `config/application.rb`, `config/environments/development.rb`

`application.rb` の class 本体先頭、他の `config.*` 行より前に `load_defaults 7.0` を追加する（明示設定の上書きを避けるため、必ず先頭）。

```ruby
module Sisito
  class Application < Rails::Application
    config.load_defaults 7.0

    # Settings in config/environments/* take precedence over those specified here.
    # Application configuration should go into files in config/initializers
    # -- all .rb files in that directory are automatically loaded.

    # Rails 7.2では明示的にSprocketsを有効にする必要がある
    config.add_autoload_paths_to_load_path = true

    # アセットパイプラインの設定
    config.javascript_path = "javascript"

    # Active Recordのタイムゾーン設定
    config.active_record.default_timezone = :local
    config.active_record.schema_format = :ruby
  end
end
```

`development.rb` から重複行を削除する（`application.rb` が全環境に対して既に設定するため）。

```ruby
Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # (config.load_defaults 7.0 の行を削除)

  # In the development environment ...
```

**Pi 検証**: 上記「共通の Pi 検証手順」を実施する。

この PR の時点で test/production 環境の署名鍵導出（`key_generator_hash_digest_class`）が development と揃う（副次効果、research.md 参照）。

### Unit 2: `load_defaults 7.0 → 7.1`

対象: `config/application.rb`

```ruby
config.load_defaults 7.1
```

Research で洗い出した 7.1 の影響項目（`add_autoload_paths_to_load_path`, `action_dispatch.default_headers`, `active_support.message_serializer`, `active_record.belongs_to_required_validates_foreign_key` 等）はいずれも影響なしと確認済み（research.md 参照）。

追加で確認済み（`w9:p2` レビュー、`configuration.rb` v7.2.3.2 で裏取り）: `load_defaults 7.1` は `Rails.env.local?` の場合に `log_file_size = 100 * 1024 * 1024`（100MB）を設定する。Pi は development 環境（`Rails.env.local?` は development/test で true）なので、`log/development.log` が Rails 側で100MBごとにローテートされるようになる。Pi に外部 logrotate が設定されている場合は二重管理になりうる（未確認）。

**Pi 検証**: 共通手順に加えて、`log/` ディレクトリの状態（ローテートファイルの有無、外部 logrotate 設定の有無）を確認する。

### Unit 3: `load_defaults 7.1 → 7.2`

対象: `config/application.rb`

```ruby
config.load_defaults 7.2
```

このバージョンで YJIT が自動有効化される（`yjit = true`、環境非依存）……はずだったが、Pi 上で `mise exec -- ruby -e 'p defined?(RubyVM::YJIT)'` を実行したところ `nil`。Pi の Ruby 3.4.9（mise管理、aarch64-linux）は YJIT非対応ビルドで、Rails側は `initializer :enable_yjit` を `if config.yjit && defined?(RubyVM::YJIT.enable)` でガードしている（`railties/lib/rails/application/finisher.rb` v7.2.3.2 L231-234、一次ソース確認済み）ため、この環境では単に no-op になる。したがってメモリ増加の懸念は実質発生しない。8.1 まで到達すれば development では自動的に無効へ戻る（`yjit = !Rails.env.local?`）ため、いずれにせよ一時的な設定である点は変わらない。

**Pi 検証**: 共通手順に加えて、`RubyVM::YJIT` が未定義のままであること（=no-opの確認）を再確認する。

### Unit 4: `new_framework_defaults.rb` の削除（gem バンプ前に必須）

対象: `config/initializers/new_framework_defaults.rb`（削除）

Unit 1〜3 完了後、この initializer の全行がノーオペになっている（`load_defaults 7.2` 以降ではいずれの項目も同じ値が既定。`w9:p2` レビューで再確認: `load_defaults` の "5.0" ブロックが `ActiveSupport.to_time_preserves_timezone = true` を直接設定するため、この行は既に "5.0" 到達時点でノーオペになっている）。ファイルごと削除する。`ssl_options` の移設は不要（research.md で検証済み: `force_ssl` 未設定のためどの環境でも無効）。

```bash
git rm config/initializers/new_framework_defaults.rb
```

独立 PR とし、Unit 5（gem バンプ）より前にマージする（`to_time_preserves_timezone` が Rails 8.0 で deprecation 警告を出すため）。

### Unit 5: Gemfile の `rails` を `~> 8.1` へ

対象: `Gemfile`, `Gemfile.lock`

```diff
-gem 'rails', '~> 7.2', '>= 7.2.3.2'
+gem 'rails', '~> 8.1'
```

```bash
bundle lock --update=rails --conservative
git diff Gemfile.lock  # 巻き込み範囲を確認
```

`--conservative` がメジャーバンプで共有依存の解決に失敗した場合は `--conservative` を外すか、影響する gem（`sprockets-rails`, `jbuilder` 等）を明示列挙して再試行する。

gem 互換性調査（`.claude/docs/research/2026-09-13-rails-8-gem-compat-survey.md`）を踏まえ、以下は個別確認する:
- `spring`/`spring-watcher-listen`: development専用。非互換でも Pi の Puma 実運用への影響は無い見込みだが、`bundle install` 時にエラーが出ないか確認
- `kaminari`: ジェネレータのみの既知バグ（実害無しと判断済み）。`bundle lock` の解決自体が通るかのみ確認
- `bootstrap-sass`/`c3-rails`/`bootstrap3-datetimepicker-rails`/`clipboard-rails`/`rack-health`: 対応不明判定。`bundle lock` が通り、CI が green であれば当面の受け入れ基準とする

`w9:p2` レビューで追加: この Unit では config だけでなく gem 自体が変わるため、`rails app:update` の差分確認（spec.md の方針）を実行する。ローカルでは `app:update` を実行できないため、https://railsdiff.org/ で 7.2.3.2 → 8.1.x の `config/environments/*.rb`・`config/puma.rb`・`bin/*` の差分を確認し、取り込むべき行があれば `development.rb`/`production.rb` を上書きせず手で反映する（research.md「`app:update`で最も危険なのは`development.rb`」参照）。

**Pi 検証**:
1. Puma 停止前に `bundle install`（Pi 上、`vendor/bundle` 隔離、CLAUDE.md「Local Environment Constraints」参照）を完了させる
2. `spring stop`
3. `RAILS_ENV=development bin/rails runner 'puts "boot ok"'` で起動確認
4. `bin/deploy.sh` で Puma 再起動
5. 主要経路一巡

`bin/sync-and-ingest.sh` の cron 実行時間帯（20:00）を避けて作業する。

### Unit 6: `load_defaults 7.2 → 8.0`

対象: `config/application.rb`

```ruby
config.load_defaults 8.0
```

Research で確認済みの影響項目（`to_time_preserves_timezone = :zone`, `Regexp.timeout ||= 1`）はいずれも実害なし見込み。`Regexp.timeout` については `bin/sync-and-ingest.sh` が同一 Rails プロセス内で Sisimai 解析を行っているか未確認のため、Pi 検証時に `sync-and-ingest.sh` の次回実行（cron、20:00）のログも確認する。

**Pi 検証**: 共通手順に加えて、`sync-and-ingest.sh` の次回 cron 実行ログを確認する。

### Unit 7: `load_defaults 8.0 → 8.1`

対象: `config/application.rb`

```ruby
config.load_defaults 8.1
```

8.1 追加項目のうち影響しうるのは以下の2点（`w9:p2` レビューでコードを直接確認済み）。

- `yjit = !Rails.env.local?`（development では無効化される、Unit 3 の懸念が解消）
- `action_controller.action_on_path_relative_redirect = :raise`: `whitelist_mails_controller.rb:94, 109` の `redirect_to params[:return_to]` が対象。`return_to` を渡している呼び出し元12箇所（`app/views/bounce_mails/_search_form.html.erb`, `show.html.erb`、`app/views/admin/_search_form.html.erb`, `_bounce_over.html.erb`, `_repeated_bounced.html.erb`, `show.html.erb`）は全てルートヘルパー（`bounce_mails_path`, `bounce_mail_path(...)`, `admin_search_path`, `admin_index_path(...)`, `admin_path(...)`）で生成しており必ず `/` 始まりになるため、通常操作では raise しない。手打ちで相対パス以外の値を `return_to` に渡すような操作をされない限り影響なし

また `action_controller.escape_json_responses = false` により、`StatusController` の `render json:` レスポンスで `<`, `>`, `&` が `<` 形式でエスケープされなくなる。JSON として意味的に等価であり、監視側が正しくJSONパースしていれば影響は無い。

**Pi 検証**: 共通手順に加えて、`/whitelist_mails` のリダイレクト経路（`admin`・`bounce_mails` 双方の起点から）を一巡する。

## 影響範囲

- 既存テスト（`within_period`/`chart_columns`/status/controller、13件）への影響: 無い見込み。CI（`.github/workflows/test.yml`）で各 Unit ごとに green を確認する。
- API変更: 無し（外部公開インターフェースの変更は無い）。
- マイグレーション: 無し。
- ドキュメント: `CLAUDE.md` の Technology Stack（「currently 7.2.3.1」は既に 7.2.3.2 で stale）、Testing セクション、Gotcha 3/6（stale test・`heads/Rails_v7.2.3.1` 記載）も stale だが、これは今回のアップグレードとは独立した既存の記載ズレであり、本計画のスコープ外。ユーザーが希望すれば最終 PR で合わせて修正する（残決定事項参照）。

## 考慮事項

- パフォーマンス: YJIT 有効化（Unit 3〜7）によるメモリ使用量増加を Pi 上で計測する。
- セキュリティ: 各 Unit マージ後、`bundler-audit check --update` で vulnerabilities 0 を維持する。
- 後方互換性: `load_defaults` の各段階は Rails 標準の後方互換パスであり、独自の互換シムは追加しない。

## 残決定事項（判断ポイント）

### 論点1: `CLAUDE.md` の stale 記載をどう扱うか

Technology Stack の Rails バージョン表記、Testing セクション（stale test・no test CI の記述、実際は PR #42 で解消済み）、Gotcha 3（stale test）・Gotcha 6（`heads/Rails_v7.2.3.1` ブランチ表記、実際は `master`）が、今回のアップグレード以前から stale。

- A. 今回のアップグレード完了時（Unit 7 マージ後）に、バージョン表記と Gotcha 3/6 のみ合わせて更新する — 利点: 「アップグレードのたびに古い版数が残る」再発を防ぐ / 欠点: アップグレード本体と無関係な修正が混ざる
- B. 今回は触れず、別途対応する — 利点: スコープを厳密に保つ / 欠点: 対応が先送りになる
- C. その他（自由記述）

推奨: A（バージョン表記の更新はアップグレードの直接の結果であり、同じ PR で更新するのが自然。Testing セクション・Gotcha 3 は既に stale なので、触れるなら合わせて直す）。`w9:p2` レビューで補足: `CLAUDE.md` の「Database Schema」節にある `ActiveRecord::Schema[7.2]` の記述は、今回マイグレーションを伴わない（`db/schema.rb` を再ダンプしない）ため更新対象に含めなくてよい。
[Answer]: A

### 論点2: Unit の PR 分割粒度

7 Unit すべてを個別 PR にする（現在の計画）か、いくつか合流させるか。

- A. 7 Unit = 7 PR（現在の計画どおり）— 利点: 問題発生時の切り分けが最も細かい / 欠点: PR 数が多く、都度 Pi 検証を挟むため時間がかかる
- B. Unit 1〜3（load_defaults 7.0/7.1/7.2 一本化）を1 PR にまとめ、Unit 4（削除）・Unit 5（gem バンプ）・Unit 6〜7（8.0/8.1）を個別 PR にする — 利点: 影響の少ない Unit 1〜3 をまとめて Pi 検証の往復回数を減らせる / 欠点: 3段階のうちどれが原因か切り分けにくくなる
- C. その他（自由記述）

推奨: A（ステージング無し環境では切り分け精度を優先する。過去のPR #44/#45の教訓「無関係な変更を混ぜない」の精神にも合う）。`w9:p2` レビューでも合意: Unit 2・3は1行差分だが、Pi上で観測できる変化（7.1のログローテート、7.2のYJIT）がそれぞれ別に載っているため分けておく価値がある。
[Answer]: A

## タスクリスト

7 Unit = 7 PR（論点2で確定）。各 Unit は前段の Pi 検証完了が前提のため、全て並列不可・逐次実行（ステージング無し環境で切り分け精度を優先する方針上、意図的に並列化しない）。

### ユニット1: load_defaultsのapplication.rb一本化（並列不可: 依存 = なし）
- [x] 1-1: `config/application.rb` の class 本体先頭に `config.load_defaults 7.0` を追加
- [x] 1-2: `config/environments/development.rb` から `config.load_defaults 7.0` の行を削除
- [x] 1-3: CI green を確認（audit/test とも pass）
- [x] 1-4: 共通 Pi 検証手順を実施。マージ前に隔離 git worktree で boot確認（`DISABLE_SPRING=1` 必須、Spring経由だと旧プロセスが応答することを確認済み）、マージ後に `bin/deploy.sh` 実行 → `/`, `/bounce_mails`, `/whitelist_mails`, `/sender`, `/status` が200、`/admin` が401(Digest認証の想定挙動)を確認
- [x] 1-5: PR作成・Issue紐付け・マージ（Issue #50、PR #51、squash mergeで完了）

### ユニット2: load_defaults 7.0→7.1（並列不可: 依存 = ユニット1）
- [x] 2-1: `config/application.rb` の `config.load_defaults` を `7.1` に変更
- [x] 2-2: CI green を確認
- [x] 2-3: 共通 Pi 検証手順 + `log/` ディレクトリの状態確認。`/etc/logrotate.d/sisito` が既に存在（daily, maxsize 20M, copytruncate, 14世代）。Rails内部ローテート（100MB）とは方式が異なる二重管理だが、現状のログサイズは両閾値を大きく下回り外部側が常に先に発火するため実害なしと判断
- [x] 2-4: PR作成・Issue紐付け・マージ（Issue #52、PR #53）

### ユニット3: load_defaults 7.1→7.2（並列不可: 依存 = ユニット2）
- [x] 3-1: `config/application.rb` の `config.load_defaults` を `7.2` に変更
- [x] 3-2: CI green を確認
- [x] 3-3: Pi上で `mise exec -- ruby -e 'p defined?(RubyVM::YJIT)'` を実行 → `nil`（YJIT非対応ビルド）。Rails側は`defined?(RubyVM::YJIT.enable)`でガードしているためno-opと判断（finisher.rb v7.2.3.2 L231-234で確認）
- [x] 3-4: 共通 Pi 検証手順 + メモリ使用量(`free -h`)のBefore/After比較 → 2.9Gi used のまま変化なし（no-op判断と整合）
- [x] 3-5: PR作成・Issue紐付け・マージ（Issue #54、PR #55。w9:p2レビューで軽微な文言指摘1点を反映後にマージ）

### ユニット4: new_framework_defaults.rb削除（並列不可: 依存 = ユニット3。gemバンプ前に必須）
- [x] 4-1: `git rm config/initializers/new_framework_defaults.rb`
- [x] 4-2: CI green を確認
- [x] 4-3: 共通 Pi 検証手順を実施（隔離worktreeでboot確認 → マージ後deploy.sh → 主要経路200/401）
- [x] 4-4: PR作成・Issue紐付け・マージ（Issue #56、PR #57）

**ここまで完了（2026-09-13深夜、ユーザーの承認のもと agents 間の役割分担で進行）。Unit 5 は意図的に未着手。理由は下記「Unit 5 着手前の申し送り」を参照。**

## Unit 5 着手前の申し送り

Unit 5（Gemfileのrailsを~> 8.1へ）は以下の理由でユーザー不在のまま着手しない:

- Unit 1〜4は全て設定ファイルの変更で、ロールバックは revert commit → `git pull` → Puma再起動で完結し、`vendor/bundle`には触れない。Unit 5は`bundle install`でPi上の共有gemツリー自体を書き換えるため、後戻りは「旧lockfileの復元＋再インストール」になり、半端な状態が実際に発生しうる
- `bin/sync-and-ingest.sh`が毎晩20:00に同じ`vendor/bundle`を使う。Unit 5をユーザー不在のまま深夜に実行し、起動はしても一部gemの相互作用に問題があった場合、気づくのは次のcron失敗時になる（2026年8月に診断した4日間のingestion停止と同種の再発パターン、今回は依存関係の変更幅がはるかに大きい）
- gem互換性調査（`.claude/docs/research/2026-09-13-rails-8-gem-compat-survey.md`）は22gem中15gemが「対応不明」、5gemが2013〜2019年で更新停止と判定されており、実機検証は未実施と明記されている。Unit 1〜4はRailsソースコードを直接確認して検証できたが、Unit 5の入力はそこまで確度が高くない
- `--conservative`が解決に失敗した場合のフォールバック（外すか対象gemを明示列挙）は解空間が広く、2エージェントの議論で収束させられる性質の判断ではない

ユーザーが戻ったら、Unit 5から通常の事前宣言ゲート付きで再開する。

### ユニット5: Gemfileのrailsを~> 8.1へ（並列不可: 依存 = ユニット4）
- [x] 5-1: `Gemfile` の `rails` 行を `gem 'rails', '~> 8.1'` に変更（w9:p2委譲）
- [x] 5-2: `bundle lock --update=rails --conservative` を実行し `Gemfile.lock` を再解決 → 一発で成功、フォールバック不要
- [x] 5-3: `git diff Gemfile.lock` で巻き込み範囲を確認 → rails本体13gem(7.2.3.2→8.1.3.1) + `action_text-trix`追加(actiontextの正当な新規依存) + `benchmark`/`cgi`削除のみ。他gemの巻き込み無し（Claude側で`git diff`直接確認、w9:pAがRubyGems依存ページで独立に裏取り、両者一致）
- [x] 5-4: railsdiff相当の確認（w9:p2がRailsアプリテンプレートを直接diff）→ Propshaft/SolidQueue/Kamal向けの新規アプリ既定値のみで、sisitoに取り込むべき差分は無しと判断。`development.rb`/`production.rb`は不変更
- [x] 5-5: CI green を確認
- [ ] 5-6: `bundler-audit check --update` で vulnerabilities 0 を確認
- [ ] 5-7: Pi上で `bundle install`（Puma停止前、`vendor/bundle`隔離）
- [ ] 5-8: `spring stop` → `RAILS_ENV=development bin/rails runner 'puts "boot ok"'` で起動確認
- [ ] 5-9: `bin/deploy.sh` でPuma再起動（cron実行時間帯20:00を避ける）
- [ ] 5-10: 主要経路一巡
- [ ] 5-11: PR作成・Issue紐付け・マージ

実装はw9:p2（Cursor、Fable 5.1）に委譲、複眼レビューをw9:pA（Cursor、Codex 5.3、RubyGems依存ページで独立検証）に依頼し、両ペインとも「異論なし」で収束。Claude側でも`git diff`を直接確認した。

### ユニット6: load_defaults 7.2→8.0（並列不可: 依存 = ユニット5）
- [ ] 6-1: `config/application.rb` の `config.load_defaults` を `8.0` に変更
- [ ] 6-2: CI green を確認
- [ ] 6-3: 共通 Pi 検証手順 + `bin/sync-and-ingest.sh` の次回cron実行（20:00）ログ確認
- [ ] 6-4: PR作成・Issue紐付け・マージ

### ユニット7: load_defaults 8.0→8.1（並列不可: 依存 = ユニット6）
- [ ] 7-1: `config/application.rb` の `config.load_defaults` を `8.1` に変更
- [ ] 7-2: CI green を確認
- [ ] 7-3: 共通 Pi 検証手順 + `/whitelist_mails` のリダイレクト経路（admin・bounce_mails双方の起点から）を重点確認
- [ ] 7-4: PR作成・Issue紐付け・マージ
- [ ] 7-5: （論点1で確定。ただし origin/master が Unit 1 着手前の 2026-09-13 時点でセッション外に進んでおり、PR #49 で Testing セクション・Gotcha 3 は既に修正済みと判明。残るのは以下2点のみ）`CLAUDE.md` の Technology Stack（`~> 7.2 (currently 7.2.3.1)` → `~> 8.1`）と Gotcha 6（`heads/Rails_v7.2.3.1` → 実際のブランチ運用に合わせた表記）を更新し、同PRまたは直後のPRでマージ

## Handoff

Design Spec → Research → Plan → Annotateが完了した。

- 設計仕様: `.claude/docs/specs/2026-09-13-rails-8-upgrade-spec.md`
- 調査レポート: `.claude/docs/research/2026-09-13-rails-8-upgrade-research.md`、`.claude/docs/research/2026-09-13-rails-8-gem-compat-survey.md`
- 実装計画: `.claude/docs/plans/2026-09-13-rails-8-upgrade-plan.md`（本ファイル、上記タスクリスト含む）

実装は `implement-verify-record` スキルで、ユニットごとにゲート（実装→検証→レビュー→承認）を挟みながら進める。全7ユニット完了後、検証結果を `.claude/docs/reports/2026-09-13-rails-8-upgrade-result.md` に記録する。
