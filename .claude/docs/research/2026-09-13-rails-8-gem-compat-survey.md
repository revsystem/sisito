# sisito Rails 7.2 -> 8.0 gem compatibility survey

調査日時: 2026-09-13

前提:
- 調査対象は `Gemfile` 指定の22 gem。
- 調査は読み取り専用で実施し、`Gemfile.lock` の固定版を起点に、RubyGems API/ページとGitHub公開情報を照合した。
- `bundle install`/`bundle update`/実アプリ起動は未実施。

判定基準:
- Rails 8対応済み: 最新版の公開情報で Rails 8系を含む依存条件が確認できる、またはメンテナ公式情報で Rails 8対応が明示される。
- 対応不明: Rails依存宣言がない、または宣言はあるが実運用互換を裏づける情報が不足している。
- 非対応: Rails 8での不具合が確認され、修正未リリースなどで現行最新版にリスクが残る。

## Rails 8対応済み

| gem | lock -> latest | lock版依存(rails系) | latest依存(rails系) | 判定根拠 | 注意点 |
|---|---|---|---|---|---|
| sprockets-rails | 3.5.2 -> 3.5.2 | `actionpack >= 6.1`, `activesupport >= 6.1` | 同左 | RubyGems API (`/api/v1/gems/sprockets-rails.json`, `/api/v2/rubygems/sprockets-rails/versions/3.5.2.json`), [v3.5.2 release note](https://github.com/rails/sprockets-rails/releases/tag/v3.5.2) に「Fix deprecations with Rails 8.0」 | Rails 8新規アプリで `manifest.js` 未作成だと起動時エラー化する既知事例あり（[PR #546](https://github.com/rails/sprockets-rails/pull/546), [Solidus issue #6327](https://github.com/solidusio/solidus/issues/6327)）。このrepoは `app/assets/config/manifest.js` あり。 |
| dartsass-sprockets | 3.2.1 -> 3.2.1 | `railties >= 4.0.0` | 同左 | RubyGems API (`/api/v1/gems/dartsass-sprockets.json`, `/api/v2/rubygems/dartsass-sprockets/versions/3.2.1.json`), [README](https://raw.githubusercontent.com/tablecheck/dartsass-sprockets/master/README.md) の Version Support に `Rails 6.1+` 明記 | Sprockets前提。Propshaft移行はスコープ外。 |
| jquery-rails | 4.6.0 -> 4.6.1 | `railties >= 4.2.0` | 同左 | RubyGems API (`/api/v1/gems/jquery-rails.json`, `/api/v2/rubygems/jquery-rails/versions/4.6.0.json`) でRails 8を排除する上限なし | Rails 8特有の既知不具合は今回未確認。 |
| momentjs-rails | 2.29.4.1 -> 2.29.4.1 | `railties >= 3.1` | 同左 | RubyGems API (`/api/v1/gems/momentjs-rails.json`, `/api/v2/rubygems/momentjs-rails/versions/2.29.4.1.json`) でRails 8を排除する上限なし | 最終リリース 2022-07。メンテ更新は鈍い。 |
| jbuilder | 2.13.0 -> 2.15.1 | `actionview >= 5.0.0`, `activesupport >= 5.0.0` | `actionview >= 7.0.0`, `activesupport >= 7.0.0` | RubyGems API (`/api/v1/gems/jbuilder.json`, `/api/v2/rubygems/jbuilder/versions/2.13.0.json`), [v2.15.1 release](https://github.com/rails/jbuilder/releases/tag/v2.15.1) | Rails org配下で更新継続。 |
| spring | 4.3.0 -> 4.7.0 | なし | なし | [README](https://raw.githubusercontent.com/rails/spring/main/README.md) の Compatibility で `Rails versions: 7.1+`、[PR #747](https://github.com/rails/spring/pull/747) で Rails 8.1 テスト追加 | 本repoでも既知の通り gem更新後は `spring stop` が必要。 |

## 対応不明

| gem | lock -> latest | lock版依存(rails系) | latest依存(rails系) | 判定根拠 | メンテ状態・補足 |
|---|---|---|---|---|---|
| sprockets | 4.2.1 -> 4.4.1 | なし | なし | RubyGems API (`/api/v1/gems/sprockets.json`, `/api/v2/rubygems/sprockets/versions/4.2.1.json`) ではRails依存宣言なし。 [CHANGELOG](https://raw.githubusercontent.com/rails/sprockets/main/CHANGELOG.md) に Rack 3 compatibility 記載 | gem自体は活発更新（latest 2026-08）だが、Rails互換は `sprockets-rails` 経由で判断する必要あり。 |
| bootstrap-sass | 3.4.1 -> 3.4.1 | なし | なし | RubyGems API (`/api/v1/gems/bootstrap-sass.json`, `/api/v2/rubygems/bootstrap-sass/versions/3.4.1.json`) | 最終リリース 2019-02。READMEはBootstrap 3向けで古い資産構成。事実上メンテ停滞。 |
| c3-rails | 0.4.18 -> 0.4.18 | なし | なし | RubyGems API (`/api/v1/gems/c3-rails.json`, `/api/v2/rubygems/c3-rails/versions/0.4.18.json`) | 最終リリース 2017-10。事実上メンテ停滞。 |
| bootstrap3-datetimepicker-rails | 4.17.47 -> 4.17.47 | なし | なし | RubyGems API (`/api/v1/gems/bootstrap3-datetimepicker-rails.json`, `/api/v2/rubygems/bootstrap3-datetimepicker-rails/versions/4.17.47.json`) | 最終リリース 2017-03。事実上メンテ停滞。 |
| clipboard-rails | 1.7.1 -> 1.7.1 | なし | なし | RubyGems API (`/api/v1/gems/clipboard-rails.json`, `/api/v2/rubygems/clipboard-rails/versions/1.7.1.json`) | 最終リリース 2017-06。事実上メンテ停滞。 |
| rack-health | 0.1.2 -> 0.1.2 | なし | なし | RubyGems API (`/api/v1/gems/rack-health.json`, `/api/v2/rubygems/rack-health/versions/0.1.2.json`) | 最終リリース 2013-11。事実上メンテ停止と判断。Rack 3系実績は未確認。 |
| execjs | 2.10.0 -> 2.10.2 | なし | なし | RubyGems API (`/api/v1/gems/execjs.json`, `/api/v2/rubygems/execjs/versions/2.10.0.json`) | Rails依存宣言なし。latestは2026-08で更新あり。 |
| terser | 1.2.7 -> 1.2.8 | なし | なし | RubyGems API (`/api/v1/gems/terser.json`, `/api/v2/rubygems/terser/versions/1.2.7.json`) | Rails依存宣言なし。latestは2026-07で更新あり。 |
| omniauth | 2.1.3 -> 2.1.4 | なし | なし | RubyGems API (`/api/v1/gems/omniauth.json`, `/api/v2/rubygems/omniauth/versions/2.1.3.json`) | Rails依存宣言なし。Rack互換中心に評価が必要。 |
| omniauth-google-oauth2 | 1.2.1 -> 1.2.3 | なし | なし | RubyGems API (`/api/v1/gems/omniauth-google-oauth2.json`, `/api/v2/rubygems/omniauth-google-oauth2/versions/1.2.1.json`) | Rails依存宣言なし。OmniAuth/Rack互換に追従する形。 |
| sisimai | 5.7.1 -> 5.7.2 | なし | なし | RubyGems API (`/api/v1/gems/sisimai.json`, `/api/v2/rubygems/sisimai/versions/5.7.1.json`) | Rails依存宣言なし。最新更新は2026-08で活発。 |
| spring-watcher-listen | 2.1.0 -> 2.1.0 | なし | なし | RubyGems API (`/api/v1/gems/spring-watcher-listen.json`, `/api/v2/rubygems/spring-watcher-listen/versions/2.1.0.json`) | 最終リリース 2022-09。Spring 4.7との組み合わせ実績は未確認。 |
| puma | 8.0.2 -> 8.0.2 | なし | なし | RubyGems API (`/api/v1/gems/puma.json`, `/api/v2/rubygems/puma/versions/8.0.2.json`) | Rails依存宣言なし。Rails 8で一般利用は多いが本調査では実機検証未実施。 |
| mysql2 | 0.5.6 -> 0.5.7 | なし | なし | RubyGems API (`/api/v1/gems/mysql2.json`, `/api/v2/rubygems/mysql2/versions/0.5.6.json`) | Rails依存宣言なし。AR adapter経由の互換は別途実行確認が必要。 |
| tzinfo-data | 1.2024.1 -> 1.2026.3 | なし | なし | RubyGems API (`/api/v1/gems/tzinfo-data.json`, `/api/v2/rubygems/tzinfo-data/versions/1.2024.1.json`) | Rails依存宣言なし。データgemのため影響は限定的。 |

## 非対応

| gem | lock -> latest | 判定根拠 | 影響 |
|---|---|---|---|
| kaminari | 1.2.2 -> 1.2.2 | RubyGems API (`/api/v1/gems/kaminari.json`, `/api/v2/rubygems/kaminari/versions/1.2.2.json`) ではリリースが2021-12で停止。加えて [README](https://raw.githubusercontent.com/kaminari/kaminari/master/README.md) はRails 8対応を掲げる一方、[Rails 8で `rails g kaminari:views` が失敗する未マージPR #1149](https://github.com/kaminari/kaminari/pull/1149) が残っている。 | 少なくともビュー生成機能にRails 8非互換が確認済み。既存ビューを使う運用なら回避余地はあるが、最新版gemだけで安全とは断定できない。 |

## Sprockets継続前提での重点所見

- `sprockets-rails 3.5.2` は Rails 8.0 deprecation 修正を含むため、Rails 8移行時の最低ラインとして妥当。
- `sprockets` は 4.2.0 で Rack 3対応が入っており、最新版4.4.1まで更新継続中。ただしRails連携判断は `sprockets-rails` の挙動が本体。
- 既知の地雷は「Rails 8新規アプリに `manifest.js` が無い状態で `sprockets-rails` を追加すると起動時例外」。このrepoは `app/assets/config/manifest.js` が既に存在するため、同一原因の即時クラッシュは回避できる。
- `dartsass-sprockets` は `railties >= 4.0.0` と README の `Rails 6.1+` 記載から宣言上はRails 8許容。ただし実環境での asset precompile 成否は未確認。

## 未確認事項

- Raspberry Pi実機での `RAILS_ENV=development` 起動、および `assets:precompile` 実行による最終動作確認は未実施。
- `kaminari` 以外にも、古いフロント系gem群（`bootstrap-sass`, `c3-rails`, `bootstrap3-datetimepicker-rails`, `clipboard-rails`）はRails 8公式対応の明示情報を確認できていない。
