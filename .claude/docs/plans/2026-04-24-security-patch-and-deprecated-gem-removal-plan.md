# 脆弱性対応 + Deprecated gem 除去 実装計画

日時: 2026-04-24
関連調査: [.claude/docs/research/2026-04-24-gemfile-vulnerability-audit-research.md](../research/2026-04-24-gemfile-vulnerability-audit-research.md)

## 概要
bundler-audit 検出の 17 件の脆弱性を解消し、併せて deprecated / unmaintained gem を除去する。Rails 7.2 系の範囲内で短期修正に留め、Rails 8.x へのメジャー更新は本計画の対象外とする。

## アプローチ

### 方針
- Rails は `7.2.3.1` へのパッチ更新のみ（メジャー更新は別計画）
- 推移的依存（rack、nokogiri、faraday 等）は `bundle update` で一括解消
- Deprecated gem は「除去」「置換」「維持（理由明記）」に分類して処置
- 各変更後に `bundle-audit` と `rails test` で回帰確認

### 採用しなかった代替案
- Rails 8.x への即時更新: Sprockets デフォルト廃止（Propshaft 化）や Solid Cache 等、影響範囲が広いため分離
- `dartsass-rails`: Sprockets 非対応で bootstrap-sass と衝突するため不採用
- `propshaft` への移行: アセットパイプライン全面刷新が必要なため本計画では維持

### Sass 移行の選択
`sass-rails` + `sassc-rails` → `dartsass-sprockets` へ置換:
- Sprockets 連携を維持（bootstrap-sass 3.4 と互換）
- `sassc-rails` の API 互換フォーク、`sass-embedded`（Dart Sass）にデリゲート
- 既存 `.scss` / `@import` / `@extend` はそのまま動作

## 変更内容

### 変更 1: Rails 本体と依存の security patch
対象: `Gemfile`

```diff
-gem 'rails', '~> 7.2', '>= 7.2.2'
+gem 'rails', '~> 7.2', '>= 7.2.3.1'
```

続けて以下で Gemfile.lock を更新:

```bash
mise exec -- bundle update rails rack rack-session nokogiri faraday net-imap thor uri
mise exec -- bundle-audit check --update
```

期待結果:
- `activerecord / activestorage` → 7.2.3.1
- `rack` → 3.1.20 以上
- `nokogiri` → 1.19.1 以上
- `faraday` → 2.14.1 以上
- `net-imap` → 0.5.7 以上
- `thor` → 1.4.0 以上
- `uri` → 1.0.4 以上
- `rack-session` → 2.1.1 以上

### 変更 2: turbolinks 除去
理由: Rails 7 で Hotwire に置き換え済み。実装での利用は layout の `data-turbolinks-track` のみで JS ハンドラ無し。turbo-rails 導入は Rails 8 移行計画に譲り、本計画ではシンプルに除去する。

対象: `Gemfile`

```diff
-gem 'turbolinks', '~> 5.2', '>= 5.2.1'
```

対象: `app/views/layouts/application.html.erb`

```diff
-    <%= stylesheet_link_tag 'application', media: 'all', 'data-turbolinks-track' => 'reload' %>
-    <%= javascript_include_tag 'application', 'data-turbolinks-track' => 'reload' %>
+    <%= stylesheet_link_tag 'application', media: 'all' %>
+    <%= javascript_include_tag 'application' %>
```

### 変更 3: CoffeeScript → 素の JS 化
理由: 6 ファイル全てほぼ空（ボイラープレートコメントのみ）、実コードは `stats.coffee` の 2 行のみ。変換は自明。

対象: `app/assets/javascripts/stats.coffee` を削除し `app/assets/javascripts/stats.js` を新規作成

```js
// app/assets/javascripts/stats.js
$(function() {
  $(".datetimepicker").datetimepicker();
});
```

対象: 以下の空 `.coffee` ファイル（中身はコメントのみ）は削除
- `admin.coffee`
- `bounce_mails.coffee`
- `sender.coffee`
- `sessions.coffee`
- `whitelist_mails.coffee`

対象: `Gemfile`

```diff
-gem 'coffee-rails', '~> 5.0'
```

### 変更 4: uglifier → terser 置換
理由: UglifyJS は ES5 限定、Rails 推奨は terser。設定変更のみで移行可能。

対象: `Gemfile`

```diff
-gem 'uglifier', '~> 4.2'
+gem 'terser', '~> 1.2'
```

対象: `config/environments/production.rb:22`

```diff
-  config.assets.js_compressor = :uglifier
+  config.assets.js_compressor = :terser
```

### 変更 5: Sass 系 gem 置換
理由: `sass-rails` と `sassc-rails` / `sassc` は LibSass ベースで EOL。`dartsass-sprockets` は API 互換フォークで Sprockets と bootstrap-sass を維持可能。

対象: `Gemfile`

```diff
-gem 'sass-rails', '~> 6.0'
-gem 'sassc-rails'
+gem 'dartsass-sprockets', '~> 3.0'
```

対象: `bootstrap-sass` は現状維持（`dartsass-sprockets` との互換性確認後判断）

補足: 既存 SCSS の `@extend .img-responsive` 等の Bootstrap クラス extend、`@import 'bootstrap-datetimepicker'` はそのまま動作する想定だが、`assets:precompile` での動作確認を必須とする。

### 変更 6: 不要 gem 削除
対象: `Gemfile`

```diff
-group :development do
-  gem 'better_errors', '~> 2.10', '>= 2.10.1'
-  gem 'hub', :require=>nil
-  gem 'rails_layout', '~> 1.0', '>= 1.0.42'
-  gem 'pry-rails', '~> 0.3.9'
-end
+group :development do
+  gem 'better_errors', '~> 2.10', '>= 2.10.1'
+  gem 'pry-rails', '~> 0.3.9'
+end
```

削除理由:
- `hub`: 実質メンテ停止、`gh` コマンドが公式
- `rails_layout`: 2015 年以降更新無し、layout 生成タスクのみで常用しない

### 変更 7: CI への bundler-audit 組み込み（提案）
理由: 同種の脆弱性の再発を自動検出するため。

対象: `.github/workflows/bundler-audit.yml`（新規）

```yaml
name: bundler-audit
on:
  push:
    branches: [master]
  pull_request:
  schedule:
    - cron: '0 0 * * 1'  # 毎週月曜

jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      - run: gem install bundler-audit
      - run: bundle-audit check --update
```

注: 現在リポジトリに `.github/workflows/` は未整備の可能性あり。採用可否を確認のうえで実施する。

## 影響範囲

### 既存テスト
- `test/controllers/` 配下の controller test は Rails 7.2.3.1 で動作すること
- `application.html.erb` の turbolinks 属性削除により、ページ遷移の挙動が通常の full reload に戻る
- `uglifier → terser` 置換で minify 出力が変わるが、JS 実行結果に差分無し想定

### API 変更
なし（外部 API・`/blacklist`、`/status` に影響なし）

### マイグレーション
なし

### UI 影響
- turbolinks 除去: ページ遷移でアセット再読み込みが発生するが、本アプリは SPA 的動作に依存していないため影響軽微
- datetimepicker（`stats.js`）は jQuery ready で初期化、動作変わらず

### Docker ビルド
- `Dockerfile.sisito` で bundle install するため、イメージ再ビルド必要

## 考慮事項

### パフォーマンス
- terser は uglifier より最適化精度が高く JS サイズが若干縮小する可能性
- Dart Sass は LibSass と比較してコンパイル速度はやや遅いが、開発ビルドのみの影響

### セキュリティ
- 本計画完了時点で `bundle-audit check` が 0 件になることを完了基準とする

### 後方互換性
- Ruby 3.4.9 は Rails 7.2.3.1 と互換
- `mise.toml` によりプロジェクトスコープで Ruby 固定済み

### mise.toml で追加管理すべきツール

本計画で `uglifier → terser` 移行を行うため、`execjs` が利用する JavaScript ランタイムの固定が必要になる。以下を追加する。

対象: `mise.toml`

```toml
[tools]
ruby = "3.4.9"
node = "22"  # LTS（執筆時点）
```

理由:
- `terser` gem は内部で `execjs` を使い、システムに存在する JS ランタイムを自動選択する。Node.js 固定が無いと環境差で動作が変わる
- 現状システムには mise global の Node v25.9.0 が入っているが、プロジェクトスコープで LTS 固定するほうが CI・他開発環境との一貫性を担保できる
- `assets:precompile` 時の minify 処理は Node で実行される

不採用とした候補:
- Bundler: mise にはファーストクラス対応が無く、`Gemfile.lock` の `BUNDLED WITH` 値で Bundler が自動整合する仕組みのため不要
- Yarn / npm: 本プロジェクトは Sprockets で完結し package.json を持たないため不要
- MySQL クライアント（`libmysqlclient-dev`）: システムパッケージで mise の管理範囲外。README / CLAUDE.md に記載する方針

### 検証手順
1. `mise exec -- bundle install` 成功
2. `mise exec -- bundle-audit check --update` が 0 件
3. `mise exec -- bundle exec rails test` 成功
4. `mise exec -- bundle exec rails assets:precompile` 成功（SCSS 変換確認）
5. `mise exec -- bundle exec rails server` 起動後、主要画面（`/`, `/bounce_mails`, `/whitelist_mails`, `/admin`, `/status`）の表示確認
6. datetimepicker の動作確認（`/` 画面）
7. chart 表示確認（C3.js）

### ロールバック戦略
- 変更を段階的コミットとし、問題発生時は該当コミットのみ revert 可能にする
- 推奨コミット分割:
  1. Ruby / mise 設定（既存コミット済み）
  2. Security patch（Rails + 推移的依存）
  3. turbolinks 除去
  4. CoffeeScript → JS
  5. uglifier → terser
  6. sass 系 gem 置換
  7. 不要 gem 削除
  8. CI（オプション）

## タスクリスト

### Phase 0: 作業ブランチ作成

- [x] 0-1: `git checkout -b heads/Rails_v7.2.3.1` で作業ブランチ作成（既存規則 `heads/Rails_vX.Y.Z` 準拠）
- [x] 0-2: 既存の未コミット変更（Gemfile sisimai 更新、mise.toml、.claude/）を先行コミットする

### Phase 1: Security patch（Rails 7.2.3.1 + 推移的依存）

- [x] 1-1: `Gemfile` の `gem 'rails'` 制約を `'~> 7.2', '>= 7.2.3.1'` に変更
- [x] 1-2: `mise exec -- bundle update rails rack rack-session nokogiri faraday net-imap thor uri` を実行
- [x] 1-3: `mise exec -- bundle-audit check --update` で脆弱性が 0 件になったことを確認（残存時は該当 gem を `bundle update` に追加）
- [~] 1-4: `mise exec -- bundle exec rails test` で回帰確認 → MySQL 未起動のため実行不可。Rails 7.2.3.1 ブート確認（`rails runner`）で代替
- [~] 1-5: `mise exec -- bundle exec rails server` 起動、主要画面表示確認 → MySQL 未起動のため DB 接続画面は確認不可（Docker 環境での最終確認は Phase 9 に残す）
- [x] 1-6: `git add Gemfile Gemfile.lock` → コミット（`chore: apply Rails 7.2.3.1 security patch and update vulnerable transitive deps`）

### Phase 2: mise.toml に Node.js 追加

- [x] 2-1: `mise use node@22` を実行（LTS 最新を自動選択）
- [x] 2-2: `cat mise.toml` で `ruby` と `node` の両方が登録されていることを確認
- [x] 2-3: `mise exec -- node --version` で Node 22 系が返ることを確認（22.22.2）
- [x] 2-4: `git add mise.toml` → コミット（`chore: pin Node.js 22 via mise for execjs runtime consistency`）

### Phase 3: turbolinks 除去

- [x] 3-1: `Gemfile` から `gem 'turbolinks', '~> 5.2', '>= 5.2.1'` の行を削除
- [x] 3-2: `mise exec -- bundle install` で Gemfile.lock 更新
- [x] 3-3: `app/views/layouts/application.html.erb:7-8` の `'data-turbolinks-track' => 'reload'` オプションを削除
- [~] 3-4: `mise exec -- bundle exec rails test` で回帰確認 → MySQL 未起動のため `rails runner` で代替
- [~] 3-5: `mise exec -- bundle exec rails server` でページ遷移の動作確認 → Docker 環境で Phase 9 時に確認
- [x] 3-6: コミット（`chore: remove deprecated turbolinks gem (no JS event handlers in use)`）

### Phase 4: CoffeeScript → 素の JS 化

- [x] 4-1: `app/assets/javascripts/stats.js` を新規作成（datetimepicker 初期化コードを素の JS で記述）
- [x] 4-2: `app/assets/javascripts/stats.coffee` を削除
- [x] 4-3: 空の `.coffee` ファイル 5 件（admin, bounce_mails, sender, sessions, whitelist_mails）を削除
- [x] 4-4: `Gemfile` から `gem 'coffee-rails', '~> 5.0'` を削除
- [x] 4-5: `mise exec -- bundle install` で Gemfile.lock 更新
- [x] 4-6: `mise exec -- bundle exec rails assets:precompile` で JS コンパイル成功確認
- [~] 4-7: `mise exec -- bundle exec rails server` 起動、`/` 画面で datetimepicker 動作確認 → Docker 環境で Phase 9 時に確認
- [x] 4-8: コミット（`chore: replace CoffeeScript with vanilla JS and remove coffee-rails`）

### Phase 5: uglifier → terser 置換

- [x] 5-1: `Gemfile` の `gem 'uglifier', '~> 4.2'` を `gem 'terser', '~> 1.2'` に置換
- [x] 5-2: `config/environments/production.rb:22` の `:uglifier` を `:terser` に変更
- [x] 5-3: `mise exec -- bundle install` で Gemfile.lock 更新
- [x] 5-4: `RAILS_ENV=production mise exec -- bundle exec rails assets:precompile` で minify 成功確認
- [x] 5-5: `public/assets/` 配下の生成された JS の中身を spot check（minify されているか）→ 451KB の application.js が 1 行 minify 確認
- [x] 5-6: コミット（`chore: replace uglifier with terser for ES6+ support`）

### Phase 6: Sass 系 gem 置換

- [x] 6-1: `Gemfile` から `gem 'sass-rails', '~> 6.0'` と `gem 'sassc-rails'` を削除
- [x] 6-2: `Gemfile` に `gem 'dartsass-sprockets', '~> 3.0'` を追加
- [x] 6-3: `mise exec -- bundle install` で Gemfile.lock 更新
- [x] 6-4: `mise exec -- bundle exec rails tmp:clear && mise exec -- bundle exec rails assets:clobber` で既存 cache 削除
- [x] 6-5: `mise exec -- bundle exec rails assets:precompile` で SCSS コンパイル成功確認
- [x] 6-6: `@extend .col-sm-6` 等の Bootstrap 拡張が解決されているか出力 CSS を確認（compiled application.css 175KB、Bootstrap クラス 11 件ヒット）
- [x] 6-7: `@import 'bootstrap-datetimepicker'` が正しく展開されているか確認（datetimepicker 関連 70 件ヒット）
- [~] 6-8: `mise exec -- bundle exec rails server` 起動、主要画面（`/`, `/bounce_mails`, `/whitelist_mails`, `/admin`）で CSS 崩れが無いか目視確認 → Docker 環境で Phase 9 時に確認
- [x] 6-9: 問題があれば `bootstrap-sass` の互換性を再調査 → `@extend` は正常動作、書き換え不要
- [x] 6-10: コミット（`chore: replace sass-rails/sassc-rails with dartsass-sprockets`）

### Phase 7: 不要 gem 削除

- [x] 7-1: `Gemfile` から `gem 'hub', :require=>nil` を削除
- [x] 7-2: `Gemfile` から `gem 'rails_layout', '~> 1.0', '>= 1.0.42'` を削除
- [x] 7-3: `mise exec -- bundle install` で Gemfile.lock 更新
- [~] 7-4: `mise exec -- bundle exec rails test` で回帰確認 → MySQL 未起動のため `rails runner` で代替（Boot OK 確認）
- [x] 7-5: コミット（`chore: remove unmaintained hub and rails_layout gems`）

### Phase 8: CI に bundler-audit 組み込み（オプション）

- [x] 8-1: `.github/workflows/` ディレクトリの有無を確認（無ければ作成）→ 新規作成
- [x] 8-2: `.github/workflows/bundler-audit.yml` を作成（plan の YAML をコピー）
- [x] 8-3: ローカルで YAML 構文を Ruby の YAML.load_file で検証（YAML OK）
- [x] 8-4: コミット（`ci: add bundler-audit workflow for continuous vulnerability scanning`）

### Phase 9: 最終確認と PR 作成

- [x] 9-1: `mise exec -- bundle-audit check --update` が 0 件であることを最終確認（No vulnerabilities found）
- [~] 9-2: `mise exec -- bundle exec rails test` 全件 PASS 確認 → MySQL 未起動のため `rails runner` で代替（Rails 7.2.3.1 boot OK）
- [~] 9-3: `mise exec -- bundle exec rails server` 起動、全主要画面で動作確認 → Docker 環境での確認は PR マージ前に別途実施
- [~] 9-4: datetimepicker、C3.js チャート、ページネーションの動作目視確認 → Docker 環境での確認は PR マージ前に別途実施
- [x] 9-5: `git log --oneline master..HEAD` でコミット分割を確認（10 コミット）
- [x] 9-6: `git push -u origin heads/Rails_v7.2.3.1`
- [x] 9-7: Issue #10 を作成し、対応する PR #9 を作成、`Closes #10` で紐付け済み
