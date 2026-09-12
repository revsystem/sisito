# Rails 7.2 → 8系 アップグレード 設計仕様

日時: 2026-09-13

## 目的・コンセプト

- sisito の Rails を現行 `~> 7.2, >= 7.2.3.2` から Rails 8 系へアップグレードする。
- 目的は将来のセキュリティサポート継続とフレームワークの最新化。現時点で機能不足や具体的な障害に迫られているわけではない。

## 想定利用者と利用シーンと制約

- 本番相当環境は Raspberry Pi 1台のみ（`RAILS_ENV=development` で稼働、CLAUDE.md Gotcha 7）。ステージング環境は無い。
- ローカル編集環境（このセッションの作業マシン）は MySQL も Spring も無く、`bundle exec rails test` すら実行できない（CLAUDE.md「Local Environment Constraints」）。実質的な動作検証は Pi 上でしか行えない。
- 最重要前提: **Pi は唯一の実運用ホストであり、アップグレード作業中に長時間ダウンさせられない。** 新しい Gemfile.lock を Pi に反映する際は `bundle install` 完了 → `rails runner` での起動確認 → Puma 再起動、の順を必ず守る（`bin/sync-and-ingest.sh` の夜間 cron も同じ `vendor/bundle` に依存するため、古い依存のまま Puma だけ止めると前回のインシデント（2026年8月、cron/mise/PATH起因の4日間ingestion停止）と同種の再発リスクがある）。

## スコープ

含めること:

- Gemfile の `rails` を `~> 8.1` へ更新し、関連 Rails コア gem（actionpack 等）を追随させる（論点1で確定）。
- `config.load_defaults` を段階的に引き上げ、かつ `application.rb`（全環境共通）に統一する。現状 `development.rb` にのみ `7.0` が置かれ、`production.rb`/`test.rb` には無い（＝CIは最も古い組み込みデフォルトで動いている）という既存の食い違いを、今回のアップグレードで解消する。
- `config/initializers/new_framework_defaults.rb`（Rails 5.0 アップグレード時の残骸）の要否確認と、不要なら削除。
- サードパーティ gem の Rails 8 互換性調査（Gemfile 記載の全 gem）。
- Pi 上での動作検証（`/`, `/bounce_mails`, `/whitelist_mails`, `/admin`, `/sender`, `/status` の主要経路）。
- CI（`.github/workflows/test.yml`）が Rails 8 + 新デフォルトで green になること。

含めないこと:

- Sprockets → Propshaft へのアセットパイプライン移行（別スコープ。今回は Sprockets 継続を明示的に選択する。理由は後述）。
- RuboCop 等の新規リンター導入（CLAUDE.md に「no RuboCop configured」と明記されており、本タスクの範囲外）。
- `config/initializers/sisito.rb` の `eval` 利用など、アップグレードと無関係な既存の設計上の懸念（CLAUDE.md Gotcha 1）への対応。
- Ruby バージョン自体の更新（現行 3.4.9 を維持。Rails 8 が要求する最低 Ruby バージョンとの整合のみ確認する）。

線引きの根拠: ステージング環境が無い一本道の本番ホストに対する変更なので、フレームワーク本体のアップグレードという単一目的に絞り、無関係な変更を混在させて検証面を広げない。

## アーキテクチャ設計

### 1. `load_defaults` の統一と段階的引き上げ

現状:

| ファイル | load_defaults |
|---|---|
| `config/application.rb` | なし |
| `config/environments/development.rb` | `7.0` |
| `config/environments/production.rb` | なし |
| `config/environments/test.rb` | なし |

Pi（実運用）は development 環境なので実質 `7.0` のデフォルトで動いているが、CI は test 環境で `load_defaults` 呼び出しが無いため、Rails が持つ最も古い（デフォルト値そのものの）挙動で動いている。この2つはすでに異なる挙動セットであり、CI が通っても Pi での挙動を保証しない状態が今回のアップグレード以前から存在する。

方針: `load_defaults` を `config/application.rb` に1箇所だけ書き、全環境（development / test / production）で共通の値を使うようにする。Rails 標準の構成（`application.rb` で一括指定）に合わせることで、今後同じ食い違いが再発しない形にする。

引き上げは Rails 公式アップグレードガイドの手順に倣い、`7.0 → 7.1 → 7.2 →（gem を 8.1 にバンプ）→ 8.0 → 8.1` の順に一段階ずつ行う（論点1で 8.1 系を確定）。各段階で `rails app:update`（Pi 上で実行、またはテンプレート差分のみ https://railsdiff.org/ で確認）が生成する `new_framework_defaults_X_Y.rb` の差分を確認し、Pi 上での起動・主要経路確認を挟む。一足飛びに `8.0` へ変更しない。

手順上の制約2点（Research で一次ソース確認済み）:

- rails 7.2 gem は `load_defaults "8.0"` を受け付けず `raise "Unknown version"` になる。したがって gem を 8.1 にバンプするタイミングは必ず `load_defaults 7.2` 到達後・`8.0` 引き上げ前でなければならない。
- `application.rb` に書く `config.load_defaults` は、他の明示的な `config.*` 行より**前**に置く。`load_defaults "7.1"` は `add_autoload_paths_to_load_path = false` を含むため、既存の `config.add_autoload_paths_to_load_path = true`（application.rb:16）より後に書くと上書きされてしまう。

理由: `load_defaults` は一度に多数のフレームワーク挙動を切り替える。ステージング環境が無い以上、切り替え幅を最小化してどの段階で何が壊れたかを特定できるようにする必要がある。

### 2. `new_framework_defaults.rb` の扱い

`config/initializers/new_framework_defaults.rb` は「Rails 5.0 アップグレードを楽にするための」ファイルで、`per_form_csrf_tokens`、`forgery_protection_origin_check`、`to_time_preserves_timezone`、`belongs_to_required_by_default`、`ssl_options` を明示的に設定している。Research で一次ソース確認済み: 前4項目は `load_defaults 7.0` 以降ではいずれにせよ同じ値が既定になるノーオペ。`ssl_options` の行も「独立して効く実設定」ではなく、`config.force_ssl` が真のときにしか使われない（このアプリはどの環境にも `force_ssl` を設定していない）ので現状どこでも効いておらず、削除時に他ファイルへ移設する必要は無い。

削除タイミングには制約がある。`to_time_preserves_timezone` の行は Rails 8.0 以降で deprecation 警告を出し、かつ `ActiveSupport::Railtie` の `after_initialize` によって値が上書きされる（=効果が無いまま警告だけ残る）ため、gem を 8.0 にバンプする**前**に削除しておく必要がある（論点2）。

### 3. アセットパイプライン: Sprockets 継続

Rails 8 のデフォルトは Propshaft だが、Sprockets が廃止されるわけではない。Sprockets を実際に維持しているのは `Gemfile` の `sprockets-rails`/`sprockets`/`dartsass-sprockets` と `app/assets/config/manifest.js` の存在であり（`application.rb` の `config.javascript_path`/`config.add_autoload_paths_to_load_path` は Research で確認した通り Sprockets 専用の設定ではなくRailsの通常のデフォルト値/autoload制御なので、これらの2行の要否は Propshaft 化とは別の話として扱う）、今回はこの Gemfile 構成を崩さず Sprockets 継続を選ぶ。`rails app:update` が提案する Propshaft 移行関連の変更は採用しない。

理由: アセットパイプラインの移行はそれ自体が独立した大きな変更であり、フレームワークバージョンアップと同時に行うと問題発生時の切り分けができなくなる。

### 4. gem 互換性調査の分担

Gemfile に列挙された gem 群（`sprockets-rails`, `dartsass-sprockets`, `bootstrap-sass`, `c3-rails`, `momentjs-rails`, `bootstrap3-datetimepicker-rails`, `clipboard-rails`, `jquery-rails`, `rack-health`, `execjs`, `terser`, `kaminari`, `omniauth`, `omniauth-google-oauth2`, `sisimai`, `jbuilder`, `spring` 等）について、Rails 8 対応状況（gemspec の `rails` 依存範囲、メンテナンス状況、既知の非互換）を読み取り専用で調査する。

この調査は herdr ワークスペース `w9` の別ペイン（`w9:pA`、Cursor Agent）に委譲する。理由: 読み取り専用でファイル変更を伴わず、範囲が明確に区切れる（Gemfile 記載の特定 gem 群のみ）ため、並行して進めても実装側の作業と衝突しない。`Gemfile.lock` の実際の更新・Pi 上の検証は Claude 側が担当し、委譲先には変更をさせない。

## 技術選定と根拠

- Rails のマイナー段階アップグレード手順は公式 Upgrading Ruby on Rails ガイドに従う（Research フェーズで最新版を参照し、7.2→8.0 間の破壊的変更点を洗い出す）。
- gem 更新はローカル環境の制約（CLAUDE.md「Local Environment Constraints」、`bundle install`/`bundle update` でローカルRubyにgemを入れない）に従い、`bundle lock --update=rails --conservative` で `Gemfile.lock` のみを再解決する（`bundle update` は使わない）。メジャーバンプでは `--conservative` が共有依存（`actionpack` に依存する `sprockets-rails` 等）の解決を拒み失敗する可能性があるため、失敗した場合は `--conservative` を外すか対象 gem を明示列挙して再試行し、結果は `git diff Gemfile.lock` で巻き込み範囲を確認してからコミットする。

## 要件ごとの実装方針

- `load_defaults` 引き上げ: 1段階ごとに個別コミット・個別 Pi 検証。
- Gemfile 本体更新: `rails` を `~> 8.1` に変更後、`bundle lock --update=rails --conservative` で解決し、`git diff Gemfile.lock` で巻き込み gem を確認する。
- 非互換 gem が見つかった場合、置き換え・削除・保留のいずれかを Annotation で確定する。
- Pi 検証: `bundle install`（Pi 上、`vendor/bundle` 隔離）→ `RAILS_ENV=development bin/rails runner 'puts "boot ok"'` → 主要経路の手動確認 → Puma 再起動、の順で行う。

## 性能・品質・セキュリティ上の前提

- CI（`.github/workflows/test.yml`）が Rails 8 + 新 `load_defaults` の組み合わせで green であることを、Pi 検証前の必須ゲートとする。
- テストカバレッジは限定的（`within_period`/`chart_columns`/status のみ）である点を認識し、CI green だけで完了と判断しない。Pi 上の手動経路確認を最終ゲートとする。
- `bundler-audit` が Rails 8 更新後も vulnerabilities 0 であることを確認する。

## リスクと対策

- **ステージング無し**: 上記の段階的 `load_defaults` 引き上げと、Pi 上での `bundle install` 先行確認で被害範囲を限定する。
- **cron ingestion の巻き込み**: `bin/sync-and-ingest.sh`（Pi、git 未追跡）が同じ `vendor/bundle` を使う。Puma 停止前に `bundle install` を完了させ、cron 実行時間帯（20:00）を避けて切り替え作業を行う。
- **Sprockets 関連 gem の compatibility**: 調査完了（w9:pA 委譲、`.claude/docs/research/2026-09-13-rails-8-gem-compat-survey.md`）。`sprockets-rails`/`dartsass-sprockets` は対応済み。`bootstrap-sass`/`c3-rails`/`bootstrap3-datetimepicker-rails`/`clipboard-rails`/`rack-health` は2013〜2019年で更新が止まっており「対応不明」判定——Rails 8での既知の非互換は見つかっていないが一次情報が乏しいため、Pi 上での実動作確認を重点的に行う対象とする。`kaminari` は README ではRails 8対応を掲げつつ `rails g kaminari:views` ジェネレータのみの既知バグ(kaminari#1149)があるが、sisito は既にカスタムビューをコミット済みでジェネレータを再実行しないため実害無しと判断(Claude側で追加検証済み)。
- **HTTP Digest 認証 / OmniAuth**: 確認済み・懸念なし。`Gemfile.lock` は既に `rack (3.2.6)` で、Rails 7.2 の時点で Rack 3 系に移行済み。今回のアップグレードで新たに Rack 2→3 対応が必要になるわけではない。
- **`rails app:update` が Pi の実質的な本番設定ファイル(`development.rb`)を上書きするリスク**: `config.hosts << "sisito"` が失われると Host Authorization で Pi へのアクセスがブロックされる。`development.rb`/`production.rb` へのテンプレート上書きは原則拒否し、必要な行だけ手で取り込む。
- **YJIT の自動有効化（`load_defaults 7.2` 到達時）**: 環境を問わず有効化されるため、Pi のメモリ使用量に影響しうる（Pi 上での確認が必要）。8.1 まで上げれば development では自動的に無効へ戻る。
- **`Regexp.timeout` のグローバル設定（`load_defaults 8.0` 到達時）**: `bin/sync-and-ingest.sh` が同一 Rails プロセス内で Sisimai 解析を行っている場合、1秒超のマッチで例外化しうる（Pi 上のスクリプトの実行形態は未確認）。

## 残決定事項（判断ポイント）

### 論点1: ターゲットバージョンは 8.0 系か 8.1 系か

ユーザー指示は「8系」で、8.0/8.1 のどちらを指すか未確定。

- A. Rails 8.0 系（`~> 8.0`）— 利点: 7.2 からの一段階アップグレードとして最小幅 / 欠点: セキュリティサポートが 2026-11-07 に終了する（本日 2026-09-13 から約8週間後、endoflife.date で確認）。目的が「将来のセキュリティサポート継続」である以上、着地点にすると1〜2ヶ月後には次のアップグレードが必要になる
- B. Rails 8.1 系（`~> 8.1`）— 利点: セキュリティサポートが 2027-10-10 まであり目的に合致する。gem バンプと `load_defaults` 切り替えを分離する手順（本セクション参照）を採る以上、`load_defaults` は 8.0→8.1 と1段ずつ上げられるため 8.0 系と比べて実質的な変更幅の差は小さい / 欠点: 8.1 で新たに変わるデフォルト（`yjit = !Rails.env.local?`、`action_on_path_relative_redirect = :raise` 等）を追加で検証する必要がある
- C. その他（自由記述）

推奨: B（Research で洗い出した 8.1 固有の追加デフォルトはこのアプリへの影響が小さく見込まれる一方、8.0 を着地点にする案は目的そのものと矛盾するため）
[Answer]: B

### 論点2: `new_framework_defaults.rb` の削除タイミング

Research で確認済み: 全項目が `load_defaults 7.0` 以降でノーオペ（`ssl_options` 含む、移設不要）。ただし `to_time_preserves_timezone` の行は Rails 8.0 以降で deprecation 警告を出し続けるため、**gem を 8.0 にバンプする前に削除しておく必要がある**（「後日でよい」対応ではない）。

- A. アップグレード本体のPRに含める — 利点: 削除タイミングの制約（gem バンプ前）を1つのPRの流れで自然に守れる / 欠点: ドキュメント整理的な変更とフレームワーク更新が同一PRに混ざる
- B. 別PRとして切り出すが、gem を 8.x にバンプするPRより前にマージする — 利点: PRの目的は1つに保ちつつ（本セッションの過去の教訓、PR #44/#45の分離事例と同じ考え方）、削除タイミングの制約も守れる / 欠点: PRが1つ増える
- C. その他（自由記述）

推奨: B（過去の教訓通りPRの目的は分離しつつ、「後日」ではなく「gem バンプ前」を順序として明記する）
[Answer]: B

### 論点3: gem 互換性調査を Herdr ペインに委譲するか

- A. `w9:pA`（agent_session あり）に読み取り専用の gem 互換性調査を委譲し、並行して Claude 側は `load_defaults` 引き上げの Research を進める — 利点: 独立した調査を並列化できる / 欠点: 委譲先の指摘は未検証情報として自分で裏取りする手間が発生する
- B. 委譲せず Claude 単独で調査する — 利点: 裏取りの往復が要らない / 欠点: 単独調査は時間がかかる。ユーザーは明示的に「役割分担して」と指示済み
- C. その他（自由記述）

推奨: A（ユーザーの明示指示に合致し、読み取り専用調査は分担のリスクが小さい）
[Answer]: A（実施済み。結果は `.claude/docs/research/2026-09-13-rails-8-gem-compat-survey.md`）
