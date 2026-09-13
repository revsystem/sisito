# Rails 7.2 → 8系 アップグレード 調査レポート

日時: 2026-09-13
設計仕様: [.claude/docs/specs/2026-09-13-rails-8-upgrade-spec.md](../specs/2026-09-13-rails-8-upgrade-spec.md)

## 対象範囲

- `config/application.rb`, `config/environments/{development,test,production}.rb`
- `config/initializers/*`（全16ファイル、特に `new_framework_defaults.rb`, `assets.rb`, `sisito_omniauth.rb`）
- `Gemfile`, `Gemfile.lock`
- `config.ru`, `mise.toml`
- 公式 Rails Upgrading Guide（`guides.rubyonrails.org/upgrading_ruby_on_rails.html`）、Rails 8.0 Release Notes（`guides.rubyonrails.org/8_0_release_notes.html`）

## アーキテクチャ概要（`load_defaults` の現状）

| ファイル | `config.load_defaults` |
|---|---|
| `config/application.rb` | なし |
| `config/environments/development.rb` | `7.0` |
| `config/environments/production.rb` | なし |
| `config/environments/test.rb` | なし |

Pi は `RAILS_ENV=development` で稼働する唯一の実運用ホスト（CLAUDE.md Gotcha 7）なので、実運用は `development.rb` の `load_defaults 7.0` が効いている。一方 CI（`.github/workflows/test.yml`、`RAILS_ENV: test`、確認済み: L25）は `test.rb` を読むが、そこには `load_defaults` が無いため、Rails が持つ組み込みデフォルト（`load_defaults` を一度も呼ばない状態、実質 Rails のバージョン非依存の初期値）で動いている。CI の green は「Pi の実際の挙動」を保証しない、既存のギャップである。

## 既存類似実装

該当なし（新規機能ではなくフレームワークバージョン更新のため、類似実装スキャンは対象外）。

## 既存パターンと規約

### `new_framework_defaults.rb` の中身（Rails 5.0時代の遺物）

```ruby
Rails.application.config.action_controller.per_form_csrf_tokens = true
Rails.application.config.action_controller.forgery_protection_origin_check = true
ActiveSupport.to_time_preserves_timezone = true
Rails.application.config.active_record.belongs_to_required_by_default = true
# ActiveSupport.halt_callback_chains_on_return_false = false  (コメントアウト済み)
Rails.application.config.ssl_options = { hsts: { subdomains: true } }
```

上4項目は Rails 5.0〜5.1 で正式デフォルト化された設定で、`load_defaults 7.0` 以降ならいずれにせよ `true`/`preserves_timezone: true` になる。つまり development 環境（Pi）ではこのファイルの上4行は現状ノーオペである可能性が高い。ただし production/test は `load_defaults` が無いため、このファイルが無ければ古い挙動（`false`）に戻る唯一の砦になっている——このファイルを不用意に削除すると production/test の挙動が変わる。

`config.ssl_options` の1行は当初「独立して効く実設定」と見ていたが誤りだった（Herdrペイン `w9:p2` のレビューで指摘され、`railties/lib/rails/application/default_middleware_stack.rb`(v8.0.5.1, L24-26) を直接確認して裏取り済み）。`ssl_options` は `config.force_ssl` が真のときにしか `ActionDispatch::SSL` へ渡らない。`force_ssl` はこのアプリのどの環境にも無く（`production.rb:43` はコメントアウト）、値自体も `load_defaults 5.0` が設定するデフォルト（`{ hsts: { subdomains: true } }`、configuration.rb L126）や `ActionDispatch::SSL.default_hsts_options` と同一なので、この行は現状どの環境でも効いていない。削除時に `production.rb` へ移設する必要は無く、ファイル全体を単純に削除してよい。

さらに `ActiveSupport.to_time_preserves_timezone = true` の行は Rails 8.0 以降で問題が生じる。`activesupport/lib/active_support.rb`(v8.0.5.1) では `:zone` 以外の値（`true` を含む）を渡すと deprecation 警告が出る。加えて `ActiveSupport::Railtie` が `config.after_initialize` ブロックで `ActiveSupport.to_time_preserves_timezone = app.config.active_support.to_time_preserves_timezone` を再代入する（`activesupport/lib/active_support/railtie.rb` v8.0.5.1 L99-103、確認済み）ため、initializer からの直接代入は起動完了後に上書きされる。つまり gem を 8.0 に上げた後もこの行を残すと「警告が出るだけで効果は上書きされる」状態になる。

**含意**: `load_defaults` を `application.rb` に一本化し全環境で `7.0` 以上を明示した時点で、上4行は名実ともに完全なノーオペになる（削除の最短安全タイミング）。加えて `to_time_preserves_timezone` の行は gem を 8.0 に上げる**前**に削除しておかないと deprecation 警告が発生し続ける。削除タイミングと PR の分け方は spec 論点2 で annotation により確定する。

### Sprockets 依存の明示設定

`config/application.rb`:
```ruby
config.add_autoload_paths_to_load_path = true
config.javascript_path = "javascript"
```

当初この2行を「Sprockets を維持するための明示的なオーバーライド」としていたが、`config.javascript_path = "javascript"` は `railties/lib/rails/engine/configuration.rb`(v8.0.5.1, L46) で確認した通り Rails 7.0 以降の**デフォルト値そのもの**で、Sprockets とは無関係（`app/javascript` を autoload 対象から除外するための設定）。`config.add_autoload_paths_to_load_path = true` も `$LOAD_PATH` に関する設定で、Sprockets が要求するものかは未確認（コード上のコメント「Rails 7.2では明示的にSprocketsを有効にする必要がある」の根拠は一次ソースから見つけられなかった）。Sprockets を実際に維持しているのは `Gemfile` の `sprockets-rails`/`sprockets`/`dartsass-sprockets` と `app/assets/config/manifest.js` の存在であり、`application.rb` のこの2行の要否は Rails 8 化・Propshaft 化とは独立の話として扱う。`config/initializers/assets.rb` は素の雛形のまま（`config.assets.version = '1.0'` のみ）で、Sprockets 固有の precompile 対象追加なども無い。

### Rack 3 は既に導入済み

`Gemfile.lock` 確認: `rack (3.2.6)`（L241）。Rails 7.2 の時点で既に Rack 3 系であり、Rails 8 アップグレードで新たに Rack 3 対応が必要になるわけではない。`config.ru` は `use Rack::Health` / `run Rails.application` のみで Rack 3 の呼び出し規約に問題はない。`omniauth (2.1.3)`, `omniauth-google-oauth2 (1.2.1)` も Rack 3 対応版として既にロックされている（`omniauth (~> 2.0)` 依存、L217-224）。

### Ruby バージョン要件

`mise.toml`: `ruby = "3.4.9"`。公式ガイド確認: "Rails 8.0 and 8.1 require Ruby 3.2.0 or newer"。現行 3.4.9 は要件を満たしており、Ruby 自体の更新は不要（spec のスコープ外指定と整合）。

## 重要な発見

### Rails 8.0 の破壊的変更（Release Notes より、確認済みの削除項目）

- Railties: `config.read_encrypted_secrets` 廃止、Rails コンソール拡張機能削除
- Action Pack: `allow_deprecated_parameters_hash_equality` 削除
- Action View: `form_with` への `nil` モデル指定削除、void 要素へのコンテンツ削除
- Active Record: `commit_transaction_on_non_local_return`、`allow_deprecated_singular_associations_name` 等の非推奨オプション削除、enum の旧記法削除
- Active Support: `ProxyObject` 削除
- Active Job: `use_big_decimal_serializer` 削除
- `db:migrate` をまっさらな DB に対して実行すると、マイグレーション実行前にスキーマを読み込むようになる。**解消済み**: CI（`.github/workflows/test.yml:35`、`w9:p2` レビューで再確認）は `bin/rails db:create db:schema:load` を使っており `db:migrate` は実行していないため、この変更の影響を受けない。
- 新しいパラメータ記法 `params.expect(...)` が推奨されるが、旧来の `params.require/permit` は引き続き動作する（廃止ではなく推奨変更）

`grep` での自己コードベース照合（`config.read_encrypted_secrets`, `allow_deprecated_parameters_hash_equality`, `allow_deprecated_singular_associations_name`, `use_big_decimal_serializer`, `ProxyObject` の使用有無）は Plan フェーズで実施する。

### `load_defaults` 段階引き上げの手順上の制約（一次ソース確認済み）

`w9:p2` のレビューで指摘され、`railties/lib/rails/application/configuration.rb` の該当タグを直接確認して裏取りした制約:

- **`load_defaults` は明示的な `config.*` 設定より前に書く必要がある**: `load_defaults "7.1"` は `self.add_autoload_paths_to_load_path = false` を含む（configuration.rb v7.2.3.2, "7.1" ブロック内 L4、確認済み）。`application.rb:16` の `config.add_autoload_paths_to_load_path = true` より後に `load_defaults` を書くと、この明示設定が上書きされて `false` に戻る。`application.rb` に一本化する際は class 本体の先頭、他の `config.*` 行より前に置く。
- **rails 7.2 gem は `load_defaults "8.0"` を受け付けない**: `configuration.rb v7.2.3.2` L339 に `raise "Unknown version #{target_version.to_s.inspect}"` があり、7.2系のバージョンリストに `8.0`/`8.1` は含まれない（確認済み）。したがって実際の手順は次の順序に固定される。
  1. rails 7.2 のまま `application.rb` に `load_defaults 7.0` を一本化（この時点で test/production の挙動が development と揃う）
  2. rails 7.2 のまま `load_defaults` を `7.1` → `7.2` に引き上げ
  3. `load_defaults 7.2` を維持したまま Gemfile の `rails` を `8.x` にバンプ
  4. `load_defaults` を `8.0`（→ `8.1`）に引き上げ
- **`rails app:update` はローカルで実行できない**: アプリを boot する rake タスクのため、gem が入っていないローカル環境（CLAUDE.md「Local Environment Constraints」）では実行できない。Pi 上で実行するか、テンプレート差分だけ見るなら https://railsdiff.org/ （7.2.x → 8.0.x/8.1.x の差分）で代替する。また `app:update` が生成する `new_framework_defaults_X_Y.rb` はインストール済み gem のバージョン分のみ生成される（7.2 gem なら 7_2 のみ）。

### 各段階で Pi（development 環境）に実際に影響しうる設定変更

一次ソース（`configuration.rb` の各バージョンブロック）から、このアプリのコードに関係しそうな項目のみ抜粋（`grep` で影響有無を確認済みのものは注記）。

7.0 → 7.1:
- `add_autoload_paths_to_load_path = false` — 前述の通り明示設定で `true` を維持すれば影響なし
- `action_dispatch.default_headers` に `X-Permitted-Cross-Domain-Policies`/`Referrer-Policy` が追加 — 実害なし見込み
- `active_support.message_serializer = :json_allow_marshal`、`cache_format_version = 7.1` — cookie store のセッション中身は `session[:pervious_url]`（文字列）のみ、キャッシュストアも `:null_store`/`:memory_store` のため影響なし
- `active_support.raise_on_invalid_cache_expiration_time = true` — `cache_if_production` は production 以外で `Rails.cache` を通らない（CLAUDE.md Gotcha 11）ため Pi では不活性
- `active_record.belongs_to_required_validates_foreign_key`、`default_column_serializer = nil` — `belongs_to`/`serialize` 未使用（grep 確認済み）

7.1 → 7.2:
- **`yjit = true`**: Finisher の `:enable_yjit` initializer で環境を問わず `RubyVM::YJIT.enable` が呼ばれる（`railties/lib/rails/application/finisher.rb` v8.0.5.1 L230-234 で確認）。Pi の development でも有効化される。YJIT はメモリ使用量を増やすため、RAM に余裕の少ない Pi では要注意。Pi の Ruby 3.4.9 が YJIT 対応ビルドか（`ruby -e 'p defined?(RubyVM::YJIT)'` で確認可能）、有効化後のメモリ増加量は**未確認**。8.1 まで上げると `load_defaults` の値が `yjit = !Rails.env.local?` に変わり、development では自動的に無効へ戻る（configuration.rb v8.1.3.1 "8.1" ブロックで確認済み）
- `active_record.validate_migration_timestamps = true` — `db/migrate/` の9ファイルは全て妥当な14桁タイムスタンプ（確認済み）

7.2 → 8.0:
- `active_support.to_time_preserves_timezone = :zone` — `to_time` の直接呼び出しはアプリ内に無い（grep確認済み）。`new_framework_defaults.rb` の同名設定行を先に削除しておく必要がある（前述）
- `Regexp.timeout ||= 1`（プロセス全体のグローバル設定） — アプリ内の正規表現は軽量（`/@/`、`/\A\d+\z/`等）で実害なし見込み。ただし `bin/sync-and-ingest.sh`（Pi、git 未追跡）が `rails runner` 経由で Sisimai の解析を同一 Rails プロセス内で回している場合はその処理も対象になる。**未確認**
- `action_dispatch.strict_freshness = true`（`w9:p2` レビューで追記、Unit 6 の実装時点では見落としていた項目）— `ActionDispatch::Http::Cache::Request#fresh?` の判定を RFC 7232 準拠にする設定で、`fresh_when`/`stale?` 経由でしか効かない。`app`/`lib`/`config` を grep した結果、`fresh_when`・`stale?`・`last_modified`・`http_cache_forever` の使用はゼロで、`expires_in` のヒットは全て `cache_if_production`（`Rails.cache` 側）の引数であり HTTP キャッシュ鮮度判定とは無関係。実害なしと確認済み
- 補足（`w9:p2` レビューで確認）: `to_time_preserves_timezone` の行は、実際に稼働している rails gem 8.1.3.1 の `configuration.rb` では `when "8.0"` ブロックからも削除されており、文字列自体が存在しない。Unit 4 で `new_framework_defaults.rb` を削除した判断（8.0系のdeprecation警告回避）は結論として正しいが、正確には「8.1.3.1では該当設定がそもそも load_defaults の対象から外れている」という状態になっている

一本化により test/production も `load_defaults 7.0` の対象になる副次効果として、`active_support.key_generator_hash_digest_class = SHA256`（`hash_digest_class` も同様）が test/production 環境にも入る。production ブロックは実運用されていない（CLAUDE.md Gotcha 7）ため実害はないが、変更点として記録しておく。

### Propshaft がデフォルト化（新規アプリのみ）

Release Notes: "Propshaft is now the default asset pipeline, replacing the old Sprockets system"。これは `rails new` した新規アプリのデフォルトを指す。既存アプリで Propshaft が強制されないのは `application.rb` のオーバーライド（前述の通り、実際は Sprockets 専用設定ではない）のおかげではなく、`rails app:update` が `Gemfile` を書き換えて `propshaft` gem を追加することはしない——つまり Sprockets を維持しているのは Gemfile の gem 構成そのものだから、というのが正確な理由。`app:update` が生成する差分（`bin/setup` や `Dockerfile` テンプレートなど）に Propshaft 前提の内容が混入する可能性は残るため、Plan フェーズで `app:update` の diff を1行ずつ確認する方針は変わらない。

### Rails 8.0 と 8.1 のセキュリティサポート期限（endoflife.date で確認）

- Rails 8.0: セキュリティサポート終了 2026-11-07（本日 2026-09-13 から約8週間後）
- Rails 8.1: セキュリティサポート終了 2027-10-10

目的が「将来のセキュリティサポート継続」である以上、8.0 を最終着地点にすると1〜2ヶ月後には次のアップグレードが必要になる。gem バンプと `load_defaults` 切り替えを分離する手順（前述）を採る限り、gem を 8.0 と 8.1 のどちらにしても `load_defaults` は 8.0→8.1 と1段ずつ上げられるため実質的な変更幅の差は小さい。spec 論点1 の推奨をこれに基づき見直す。

### `rails app:update` で最も危険なのは `development.rb`

Pi は `RAILS_ENV=development` で稼働しており、`development.rb` が実質的な本番設定ファイルである（CLAUDE.md Gotcha 7）。`app:update` のテンプレート差分を無条件に受け入れると、以下が失われうる。

- `config.hosts << "sisito"`（development.rb:59）— 消えると Host Authorization により Pi へのアクセスがブロックされる
- `config.assets.debug`/`config.assets.quiet`（development.rb:45, 48）— Sprockets 固有設定
- `config.load_defaults 7.0`（development.rb:4）— `application.rb` への一本化後は消えて問題ない

`production.rb` の `config.assets.js_compressor = :terser`/`config.assets.compile = false`（22, 26行目）も同様に上書きリスクがあるが、production ブロックは実運用されていないため影響は限定的。

### `load_defaults` の一本化がもたらす副次効果

CI（test 環境）は現状 Pi（development 環境）より古いデフォルトで動いている。`application.rb` への一本化はこのギャップを埋め、「CI が green → Pi でも同じ挙動」という前提を今回で初めて成立させる。これは Rails 8 化そのものとは独立した既存の技術的負債の解消であり、アップグレード作業の副産物として得られる。

## 注意点・リスク

- **ステージング環境無し**（CLAUDE.md「Local Environment Constraints」）: ローカルは MySQL/Spring が無く `bundle exec rails test` すら通らない。全ての動作確認は CI（GitHub Actions、MySQL 8.0 サービスコンテナ）と Pi 本番でのみ可能。
- **`rails app:update` の対話的プロンプト**: 各設定ファイルの上書き可否を1つずつ聞かれる。Sprockets 関連・Dockerfile 関連は機械的に「Yes」せず、diff を確認して選択する。
- **cron ingestion との `vendor/bundle` 共有**（CLAUDE.md Gotcha 9、および 2026年8月のインシデント記録 `project_pi_ingestion_arch` メモリ）: Pi 上で `bundle install` を先に完了させてから Puma を再起動する順序を厳守する。
- **Spring**: development グループの `spring`/`spring-watcher-listen` は Rails 8 で動作するか要確認（gem 互換性調査に含めた）。仮に非互換でも development 専用 gem なので Pi の実運用（`RAILS_ENV=development` だが Puma 経由でアプリケーションサーバとして動く運用であり `rails server` の対話開発ではない）への影響は限定的とみられるが、要確認。
- **`db:migrate` のスキーマ先行ロード変更**: 影響なし（確認済み。CI は `db:schema:load` を使用、`db:migrate` は使っていない）。
- **YJIT の自動有効化（7.2到達時）とメモリ使用量**: Pi の RAM に余裕が少ない場合、`load_defaults 7.2` で自動有効化される YJIT がメモリ増加を招く可能性がある。Pi 上での有効化確認とメモリ計測が必要（未確認）。
- **`Regexp.timeout` のグローバル設定（8.0到達時）**: `bin/sync-and-ingest.sh` が Rails プロセス内で Sisimai 解析を回している場合、1秒を超える正規表現マッチで例外が出る可能性がある（未確認）。
- **`rails app:update` が `development.rb` を上書きするリスク**: Pi の実質的な本番設定ファイルであり、`config.hosts << "sisito"` 等が失われるとアクセス不能になる。テンプレート上書きは原則拒否し、必要な行だけ手で取り込む。

## gem 互換性調査（w9:pA への委譲結果）

全文: [.claude/docs/research/2026-09-13-rails-8-gem-compat-survey.md](2026-09-13-rails-8-gem-compat-survey.md)

Gemfile 記載22 gem を「Rails 8対応済み」「対応不明」「非対応」の3分類で読み取り専用調査した結果（RubyGems API + GitHub公開情報が根拠、実機検証は未実施）。

- **対応済み**: `sprockets-rails`(3.5.2、Rails 8.0 deprecation修正済み), `dartsass-sprockets`, `jquery-rails`, `momentjs-rails`(メンテ鈍化), `jbuilder`, `spring`(README で Rails 7.1+ 明記、PR#747でRails 8.1テスト追加)
- **対応不明**: `sprockets`, `bootstrap-sass`(2019年最終リリース、事実上メンテ停滞), `c3-rails`(2017年最終)、`bootstrap3-datetimepicker-rails`(2017年最終)、`clipboard-rails`(2017年最終)、`rack-health`(2013年最終、事実上メンテ停止と判定)、`execjs`, `terser`, `omniauth`, `omniauth-google-oauth2`, `sisimai`, `spring-watcher-listen`, `puma`, `mysql2`, `tzinfo-data`
- **非対応**: `kaminari` — README は Rails 8対応を掲げるが `rails g kaminari:views` が Rails 8 で失敗する未マージ PR([kaminari#1149](https://github.com/kaminari/kaminari/pull/1149))が残っている

`kaminari` の判定を Claude 側で追加検証した: PR #1149 の内容を直接確認したところ、原因は `class << self` 導入時に `themes` メソッドが誤って `private` 化されたことによるジェネレータ内部の `NoMethodError` で、**ジェネレータ実行時に限定**される（ページネーションのスコープチェーンやビューレンダリングなど実行時処理には影響しないと明記されている）。sisito は `app/views/kaminari/_paginator.html.erb` 等のカスタムビューを既にリポジトリにコミット済みで、アップグレード作業で `rails g kaminari:views` を再実行する予定は無い。したがって「非対応」の判定はこのアプリの実際の使い方には当てはまらず、リスクは低いと評価する。

`bootstrap-sass`/`c3-rails`/`bootstrap3-datetimepicker-rails`/`clipboard-rails`/`rack-health` はいずれも2013〜2019年を最後に更新が止まっている「対応不明」gem群で、Rails 8 での非互換が確認されたわけではないが、動作実績の一次情報が乏しい。Sprockets/フロントエンドスタックの一部として今回のスコープ（Sprockets継続）では維持するが、Pi 上での実際の動作確認（アセットのプリコンパイル、HTTP Digest管理画面の表示、日時ピッカーの動作）を重点的に見る対象とする。

## バグ調査の場合

該当なし（新規機能・バグ修正ではなくバージョンアップグレード）。
