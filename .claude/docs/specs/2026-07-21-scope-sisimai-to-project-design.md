# update-sisto-db.rb を project-scoped sisimai に切り替える 設計

日付: 2026-07-21
状態: 設計承認済み（レビュー反映、実装計画へ）

## 目的

Pi の手動 bounce 取り込みスクリプト `update-sisto-db.rb` は、プレーンな `require 'sisimai'` で
システム gem（現在 5.4.0、`/var/lib/gems/3.2.0/gems/sisimai-5.4.0`）を読み込んでいる。これは Rails アプリの
bundle 管理下の sisimai（`vendor/bundle` の 5.7.1）とは完全に独立したインストールで、`mise exec --` の付け忘れ
で気づかず古い gem を使ってしまう事故が実際に発生した（2026-07-20〜21、サーバー起動時に類似の症状が発現）。

ユーザーの方針: 「sisimai は `~/sisito` で動けばよく、システムの sisimai は不要」。取り込みスクリプトを
プロジェクトの bundle 管理下に一本化し、システム側の独立 gem を廃止する。

## スコープ

含む。`update-sisto-db.rb` を Bundler 経由でプロジェクトの Gemfile.lock（sisimai 5.7.1、mysql2）を使うように
変更する。CLAUDE.md の起動例を更新する。`.claude/skills/sisito-deploy/SKILL.md` の前提記述（取り込みは system
ruby/sisimai で bundle とは別系統、という現状は本変更後に誤りになる）を更新する。Pi のシステム gem `sisimai`
(5.4.0) をアンインストールする。

含まない。`docker/postfix/collect.rb`（コンテナ内で別途 `gem install sisimai` する完全に別系統。外部送信専用
コンテナで取り込みには不使用）。README.md にある別の例示コード（実運用スクリプトではない旧版サンプル）。

## 変更内容

### 1. 前提確認: vendor/bundle に sisimai 5.7.1 があることを確認する

スクリプトを切り替える前に、Pi の `vendor/bundle` が Gemfile.lock の要求するバージョンを実際に持っているかを
確認する。2026-07-20 のデプロイで既に `vendor/bundle/ruby/3.4.0/gems/sisimai-5.7.1` が導入済みであることを
確認済みだが、これは今回のロールアウト手順としても明示的な前提チェックにする（将来別ホストで同じ手順を踏む
場合や、Pi の vendor/bundle が何らかの理由で欠けていた場合に、スクリプト切り替えだけが先行して壊れることを
防ぐため）。欠けていれば `bin/deploy.sh`（`sisito-deploy` スキル）を先に実行し、`bundle install` を完了させる。

```bash
ssh pi 'cd ~/sisito && ls -d vendor/bundle/ruby/*/gems/sisimai-5.7.1 2>/dev/null || echo MISSING'
```

`MISSING` が出た場合は `sisito-deploy` スキルの手順でデプロイしてから次に進む。

### 2. update-sisto-db.rb

先頭の `require 'fileutils'` より前に、`config/boot.rb` と同じパターンで `BUNDLE_GEMFILE` を明示してから
`require 'bundler/setup'` を追加する。`require 'bundler/setup'` 単体は現在の作業ディレクトリ（`Dir.pwd`）を
起点に Gemfile を探すため、スクリプトの置き場所とは別のディレクトリから呼ばれると別の Gemfile を拾う、または
見つからずに失敗する可能性がある。`__dir__` 起点で明示することでこの依存を無くす。

```ruby
#!/usr/bin/env ruby
ENV['BUNDLE_GEMFILE'] ||= File.expand_path('Gemfile', __dir__)
require 'bundler/setup'
require 'fileutils'
require 'sisimai'
require 'mysql2'
require 'tmpdir'
```

これにより `require 'sisimai'` は呼び出し時の cwd に関わらず、`update-sisto-db.rb` と同じディレクトリの
Gemfile.lock が固定する sisimai 5.7.1（および mysql2 の lock バージョン）を必ず読み込む。`mysql2`
(`~> 0.5.6`) と `sisimai` (`~> 5.7, >= 5.7.0`) はどちらも既に Gemfile にあるため、Gemfile 自体の変更は不要。

`smtpagent`/`smtpcommand` の補完ロジック（`hash['smtpagent'] ||= hash['decodedby']` 等、2026-07-19 の PR #24 で
追加済み）はそのまま。5.7.1 は 5.5.0 以上なので実際に補完が効く経路が初めて本番で通ることになる。

副次効果として、誤って `mise exec --` を付けずシステム ruby 3.2.3 で実行した場合、`vendor/bundle/ruby/3.2.0`
には sisimai 5.7.1 が存在しない（5.7.0 までしか入っていない、実機で確認済み）ため `require 'bundler/setup'` が
`Could not find sisimai-5.7.1 in locally installed gems` で即座に失敗する。これはサーバー起動時に実際に踏んだ
症状と同一のエラーメッセージで、原因の見分けがつきやすい。従来の「気づかず古いシステム gem で動いてしまう」
という静かな事故を、構造的に「明示的なエラーで止まる」事故に変える。

**運用上の注意（重要）**: この変更を反映した瞬間から、旧来の起動習慣（`mise exec --` を付けずに素の
`ruby ./update-sisto-db.rb ...` を打つこと）は即座に失敗するようになる。これはシステム sisimai 5.4.0 の
アンインストール（手順5）を待たずに起きる。Gemfile.lock は sisimai を「5.7.1 という厳密なバージョン」で
要求するため、システム sisimai 5.4.0 がまだ残っていても `require 'bundler/setup'` はそれを満たすとは見なさず、
同じ `Could not find sisimai-5.7.1` エラーになる。「システム gem をまだ消していないのに動かない」という
混乱を避けるため、この順序をユーザーに明示しておく。

### 3. 起動方法

今後の起動コマンド。

```bash
mise exec -- ruby update-sisto-db.rb /path/to/maildir
```

`bundle exec` は不要（`require 'bundler/setup'` が同等の役割を果たす）。`mise exec --` は必須（`vendor/bundle`
は ruby の ABI バージョンごとに分かれているため、正しい ruby 3.4.9 を選ぶ必要がある）。

### 4. CLAUDE.md の更新

`### \`update-sisto-db.rb\`` 節の起動例を新しいコマンドに置き換える。

```diff
 ```bash
-ruby update-sisto-db.rb /var/spool/sisito/mail
+mise exec -- ruby update-sisto-db.rb /var/spool/sisito/mail
 ```
```

### 5. sisito-deploy スキルの更新

`.claude/skills/sisito-deploy/SKILL.md` の「前提」節にある次の記述は、本変更後は誤りになるため書き換える。

現状（誤りになる）:

> 取り込み（`update-sisto-db.rb`）は system ruby と system sisimai で動き、bundle とは別系統。
> Gemfile の gem を上げても取り込み挙動は変わらない。

変更後:

> 取り込み（`update-sisto-db.rb`）は 2026-07-21 以降、`require 'bundler/setup'` によりプロジェクトの
> Gemfile.lock（bundle の sisimai）を使う。起動は `mise exec -- ruby update-sisto-db.rb <maildir>`
> （`bundle exec` は不要）。`mise exec --` を付け忘れると `Could not find sisimai-X.X.X in locally
> installed gems` で失敗する（サーバー起動時と同じ症状）。

あわせて「詰まったとき」節の既存の `Could not find <gem>-<version>` の項目は `rails server` の文脈で
書かれているため、`update-sisto-db.rb` にも同じ症状が起き得ることを明記する一文を追加する。

### 6. システム sisimai のアンインストール

Pi 上で実行する。`/var/lib/gems` は root 所有で `pi` からは書き込めないが、`pi` はパスワード無し sudo が使える
ことを確認済み。

```bash
sudo gem uninstall sisimai
```

「2. update-sisto-db.rb」の変更を反映した後に実行する。切り替え前に消すと取り込みが完全に動かなくなるため
順序を守る（手順2の運用上の注意にあるとおり、切り替え直後は未アンインストールでも旧起動習慣は既に失敗する
ため、アンインストール自体のタイミングによる追加リスクは小さいが、切り替え前の状態に戻す必要が生じた場合に
備えて順序は明確にしておく）。

**実装計画での追加制約**: 「反映した後」とは、ローカルブランチでの変更やテスト用の一時 checkout ではなく、
PR がマージされ、本番の Pi へ実際にデプロイされたことを指す。ロールアウトはブランチを Pi 上で一時的に
checkout してテストし、システム gem には触れないまま master へ戻す（この間は正しい起動方法 `mise exec --`
のみでテストする）。その後 PR をマージし、通常のデプロイ経路で本番反映してから、初めてアンインストールする。
これは実装計画（writing-plans）の自己レビューで、素朴な「切り替え直後にアンインストール」という読み方だと
ブランチテスト後に master へ戻すタイミングでシステム gem が既に無い状態になり、マージ待ちの間 Pi の取り込み
が完全に壊れる時間帯が生まれることに気づいて追加した安全策。詳細は実装計画側の Architecture と Task 3〜6 を
参照。

## 検証

本番の bounce_mails に重複行を作らないため、実メールの eml では検証しない（`digest` 列は index のみで
unique 制約が無く、再取り込みは重複挿入になる）。空の一時ディレクトリを使い、初期化経路（Bundler.setup →
sisimai 読み込み → mysql2 接続）だけを確認する。すべて `cd ~/sisito` した上で実行する（`update-sisto-
db.rb` 自体は `__dir__` 起点の `BUNDLE_GEMFILE` で cwd に依存しなくなるが、検証に使う `ruby -e` のワンライナー
は cwd に依存するため、両者を同じ条件で確認する目的で統一する）。

- 空ディレクトリを用意し `cd ~/sisito && mise exec -- ruby update-sisto-db.rb <空の一時ディレクトリ>`
  を実行する。`Sisimai.rise` が空配列を返し何も INSERT されずに正常終了することを確認する（sisimai 5.7.1 と
  mysql2 の require が成功したことの間接確認）。
- 非破壊的に sisimai バージョンだけを直接確認する: `cd ~/sisito && mise exec -- ruby -e "require
  'bundler/setup'; require 'sisimai'; puts Sisimai::VERSION"` の出力が `5.7.1` であることを確認する。
- `mise exec --` を付けずに同じ空ディレクトリで `cd ~/sisito && ruby update-sisto-db.rb <path>` を
  実行し、`Could not find sisimai-5.7.1 in locally installed gems` で明確に失敗することを確認する
  （フェイルセーフの動作確認、DB 接続前に落ちるため安全）。
- システム gem アンインストール後、`gem list sisimai`（システム ruby）が空になることを確認する。
- アンインストール後も `cd ~/sisito && mise exec -- ruby update-sisto-db.rb <空の一時ディレクトリ>` が
  問題なく動くことを再確認する（システム gem 削除後もプロジェクト側だけで完結することの確認）。
- 実データでの取り込み確認は、次回の実際の eml 取り込み作業時に自然に行われるため、本設計の検証には含めない。

## 関連

- `.claude/skills/sisito-deploy/SKILL.md`（`mise exec --` を付け忘れた場合の同種の症状は現状 `rails server`
  の文脈でのみ記載されており、取り込みスクリプトについては system-gem 前提の古い記述のまま。手順5で更新する）
- `memory/project_pi_ingestion_arch.md`（Pi の取り込みアーキテクチャの一次記録。本変更後に更新する）
- PR #24（`update-sisto-db.rb` の smtpagent/smtpcommand 補完ロジックを追加した変更）
