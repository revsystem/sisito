# Scope sisimai to project (update-sisto-db.rb) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pi 上の手動 bounce 取り込みスクリプト `update-sisto-db.rb` を、システム側の独立 sisimai gem ではなく、プロジェクトの Gemfile.lock（bundle）が管理する sisimai を使うように切り替え、システム側の sisimai gem を廃止する。

**Architecture:** `update-sisto-db.rb` の先頭に `config/boot.rb` と同じパターンで `ENV['BUNDLE_GEMFILE']` を明示してから `require 'bundler/setup'` を追加し、cwd に依存せず常にプロジェクトの Gemfile.lock（sisimai 5.7.1）を読み込むようにする。ローカルで編集・コミットしたブランチを Pi 上で一時的に checkout してテストし、システム gem には一切触れないまま master へ戻す。その後 PR をマージし、通常の `bin/deploy.sh`（git pull）で本番反映してから、初めてシステム sisimai をアンインストールする。この順序により、正しい起動方法（`mise exec --` 付き）を使う限り、作業のどの時点でも Pi の取り込みが壊れた状態にならない。ただし Task 2 のコード変更が Pi に反映された時点（Task 3 のテスト checkout 中、および Task 5 のデプロイ後）から、`mise exec --` を付けない旧来の起動方法は意図的に即失敗するようになる。これは事故防止のための想定内の挙動であり、正しい起動方法とは区別して扱う。

**Tech Stack:** Ruby（Bundler）、mise、SSH、Rails 7.2、sisimai gem

## Global Constraints

- スクリプトの起動は今後 `mise exec -- ruby update-sisto-db.rb <maildir>`（`bundle exec` は不要）。
- `update-sisto-db.rb` は `config/boot.rb` と同じパターン（`ENV['BUNDLE_GEMFILE'] ||= File.expand_path('Gemfile', __dir__)` → `require 'bundler/setup'`）で cwd に依存しないようにする。
- 検証は実 eml を使わない。`bounce_mails.digest` に unique 制約が無く、重複挿入のリスクがあるため。
- Pi (`pi`) への接続は `ssh pi`（`~/.ssh/config` の Host pi、ed25519 鍵、非対話）。Pi 上のプロジェクトパスは `~/sisito`。`pi` ユーザーはパスワード無し sudo が使える（確認済み）。
- **システム sisimai のアンインストールは、PR マージ後に本番デプロイが完了し、新スクリプトが実際に動くことを確認してから最後に行う。** 途中のブランチテスト段階では絶対にシステム gem へ触れない。順序を守らないと、テスト後に master へ戻した時点で Pi の取り込みが完全に壊れる時間帯が生まれる。
- `docker/postfix/collect.rb` と README.md の別サンプルはスコープ外。触らない。
- ローカルリポジトリでの編集は新規ブランチ `heads/scope_sisimai_to_project`（`origin/master` から作成）で行う。

---

### Task 1: vendor/bundle の前提を確認する

**Files:**
- 変更なし（読み取り確認のみ）

**Interfaces:**
- Consumes: なし
- Produces: 「Pi の vendor/bundle に sisimai 5.7.1 が存在する」という事実確認（Task 3 の前提）

- [ ] **Step 1: vendor/bundle に sisimai 5.7.1 があるか確認する**

```bash
ssh pi 'cd ~/sisito && ls -d vendor/bundle/ruby/*/gems/sisimai-5.7.1 2>/dev/null || echo MISSING'
```

Expected: `vendor/bundle/ruby/3.4.0/gems/sisimai-5.7.1` が出力される。

- [ ] **Step 2: MISSING だった場合のみ、デプロイを先に実行する**

Step 1 が `MISSING` を出力した場合に限り実行する。5.7.1 が確認できていれば、この Step はスキップして Task 2 に進む。

`bin/deploy.sh` は `git pull --ff-only` を含むため、Pi の追跡ファイルに未コミット変更があると失敗する
（このセッションで実際に発生した事例がある）。直接デプロイを叩く前に `sisito-deploy` スキルの手順2
（作業ツリー確認、必要なら stash）を先に行う。

```bash
ssh pi 'cd ~/sisito && git status --short'
```

Expected: 追跡ファイルに変更なし（未追跡の `Gemfile.lock.tmp` 等は無視してよい）。変更があれば
`sisito-deploy` スキルの手順どおり `git stash push -m <理由> -- <file>` で退避してから次に進む。

```bash
ssh pi 'bash -lc "cd ~/sisito && ./bin/deploy.sh"'
```

Expected: `Bundle complete!` の出力後、Step 1 を再実行して `vendor/bundle/ruby/3.4.0/gems/sisimai-5.7.1` が出ること。

---

### Task 2: 作業ブランチで update-sisto-db.rb を編集し、CLAUDE.md / SKILL.md を更新する

**Files:**
- Modify: `/home/tsuyoshi/go/src/github.com/revsystem/sisito/update-sisto-db.rb:1-5`
- Modify: `/home/tsuyoshi/go/src/github.com/revsystem/sisito/CLAUDE.md`（`update-sisto-db.rb` 節の起動例）
- Modify: `/home/tsuyoshi/go/src/github.com/revsystem/sisito/.claude/skills/sisito-deploy/SKILL.md`（前提節、詰まったとき節）

**Interfaces:**
- Consumes: なし
- Produces: push 可能な状態のブランチ `heads/scope_sisimai_to_project`（Task 3 が Pi 上で checkout する）

- [ ] **Step 1: 現在のブランチと状態を確認する**

```bash
cd /home/tsuyoshi/go/src/github.com/revsystem/sisito
git branch --show-current
git status --short
```

Expected: 追跡ファイルに変更なし（未追跡の `.claude/docs/` や `.claude/handovers/` は無視してよい）。

- [ ] **Step 2: 作業ブランチを作成する**

```bash
git fetch origin
git checkout -b heads/scope_sisimai_to_project origin/master
```

Expected: `Switched to a new branch 'heads/scope_sisimai_to_project'`

- [ ] **Step 3: update-sisto-db.rb の1〜5行目を編集する**

現在の内容:

```ruby
#!/usr/bin/env ruby
require 'fileutils'
require 'sisimai'
require 'mysql2'
require 'tmpdir'
```

これを次に置き換える。

```ruby
#!/usr/bin/env ruby
ENV['BUNDLE_GEMFILE'] ||= File.expand_path('Gemfile', __dir__)
require 'bundler/setup'
require 'fileutils'
require 'sisimai'
require 'mysql2'
require 'tmpdir'
```

- [ ] **Step 4: CLAUDE.md の起動例を確認し、更新する**

```bash
grep -n "ruby update-sisto-db.rb" CLAUDE.md
```

Expected: `ruby update-sisto-db.rb /var/spool/sisito/mail` を含む行が見つかる。

該当ブロック:

```
```bash
ruby update-sisto-db.rb /var/spool/sisito/mail
```
```

これを次に置き換える。

```
```bash
mise exec -- ruby update-sisto-db.rb /var/spool/sisito/mail
```
```

- [ ] **Step 5: SKILL.md の前提節を確認し、更新する**

```bash
sed -n '/^## 前提/,/^## 手順/p' .claude/skills/sisito-deploy/SKILL.md
```

Expected: 「取り込み（`update-sisto-db.rb`）は system ruby と system sisimai で動き、bundle とは別系統。Gemfile の gem を上げても取り込み挙動は変わらない。」の行が見つかる。

該当行:

```
- 取り込み（`update-sisto-db.rb`）は system ruby と system sisimai で動き、bundle とは別系統。
  Gemfile の gem を上げても取り込み挙動は変わらない。
```

これを次に置き換える。

```
- 取り込み（`update-sisto-db.rb`）は 2026-07-21 以降、`require 'bundler/setup'` によりプロジェクトの
  Gemfile.lock（bundle の sisimai）を使う。起動は `mise exec -- ruby update-sisto-db.rb <maildir>`
  （`bundle exec` は不要）。`mise exec --` を付け忘れると `Could not find sisimai-X.X.X in locally
  installed gems` で失敗する（サーバー起動時と同じ症状）。
```

- [ ] **Step 6: SKILL.md の詰まったとき節に一文を追加する**

既存行（`.claude/skills/sisito-deploy/SKILL.md` 末尾付近）:

```
- `bundle exec rails server` で `Could not find <gem>-<version> in locally installed gems` →
  `mise exec --` を付けずに実行したため、PATH 上の別 ruby（system ruby 3.2.3、`vendor/bundle/ruby/3.2.0`）
  に化けている。この vendor パスはデプロイで更新されないので gem が古いまま。
  必ず `RAILS_ENV=development mise exec -- bundle exec rails server -p 1080 -b 0.0.0.0` の形で実行する。
```

この直後に次の行を追加する。

```
- `ruby update-sisto-db.rb` で同様のエラー → 同じ原因。`update-sisto-db.rb` も `require 'bundler/setup'`
  で bundle 管理下の gem を使うため、`mise exec -- ruby update-sisto-db.rb <maildir>` の形で実行する。
```

- [ ] **Step 7: 変更内容を確認する**

```bash
head -8 update-sisto-db.rb
grep -n "mise exec -- ruby update-sisto-db.rb" CLAUDE.md
grep -n "2026-07-21\|update-sisto-db.rb" .claude/skills/sisito-deploy/SKILL.md
```

Expected: いずれも Step 3〜6 で書いた内容がそのまま見つかる。

- [ ] **Step 8: update-sisto-db.rb と CLAUDE.md をコミットする**

`.claude/skills/` は `.gitignore` 対象のためこのコミットには含まれない（別途 Task 6 で chezmoi へ反映する）。

```bash
git add update-sisto-db.rb CLAUDE.md
git commit -m "fix(ingest): load sisimai via project Bundler instead of a system gem

require 'bundler/setup' now runs before requiring sisimai/mysql2, pinning
both to the versions in Gemfile.lock (sisimai 5.7.1) regardless of which
system-wide gems happen to be installed. BUNDLE_GEMFILE is set relative to
__dir__ (same pattern as config/boot.rb) so this holds regardless of the
caller's working directory. Running without 'mise exec --' now fails fast
with 'Could not find sisimai-5.7.1 in locally installed gems' instead of
silently falling back to a stale system gem."
```

- [ ] **Step 9: git status を確認する**

```bash
git status --short
```

Expected: `update-sisto-db.rb` と `CLAUDE.md` はコミット済みで表示されない。`.claude/skills/` も表示されない（gitignore 対象）。

---

### Task 3: ブランチを push し、Pi 上で一時的に checkout してテストする

**Files:**
- 変更なし（Pi 上での一時的な git checkout とテスト実行のみ）

**Interfaces:**
- Consumes: Task 2 でコミットしたブランチ `heads/scope_sisimai_to_project`
- Produces: 「新しい起動方法が動く」「古い起動方法は安全に失敗する」の実測結果。テスト後は Pi を master に戻す（Task 4 の前提）

**注意:** Step 3〜7 の間、Pi は一時的にこのブランチを checkout した状態になり、`mise exec --` を付けない
旧来の起動方法は即失敗する。この窓では実際の eml 取り込み作業を行わないこと。Step 3 から Step 8（master
復帰）までを間を空けずに連続して実行し、窓を最短にする。

- [ ] **Step 1: ブランチを push する**

```bash
cd /home/tsuyoshi/go/src/github.com/revsystem/sisito
git push -u origin heads/scope_sisimai_to_project
```

- [ ] **Step 2: Pi が master でクリーンであることを確認する**

```bash
ssh pi 'cd ~/sisito && git branch --show-current && git status --short'
```

Expected: `master`。追跡ファイルに変更なし（`Gemfile.lock.tmp` 等の未追跡ファイルは無視してよい）。

- [ ] **Step 3: Pi 上でブランチを fetch して一時 checkout する**

```bash
ssh pi 'cd ~/sisito && git fetch origin && git checkout -B heads/scope_sisimai_to_project origin/heads/scope_sisimai_to_project'
```

Expected: `Switched to a new branch 'heads/scope_sisimai_to_project'`

- [ ] **Step 4: 空の一時ディレクトリを用意する**

```bash
ssh pi 'mkdir -p /tmp/sisimai-verify-empty'
```

- [ ] **Step 5: 正しい起動方法で実行し、正常終了することを確認する**

```bash
ssh pi 'bash -lc "cd ~/sisito && mise exec -- ruby update-sisto-db.rb /tmp/sisimai-verify-empty; echo EXIT=$?"'
```

Expected: `EXIT=0`。`SQL = ` から始まる INSERT ログは出力されない（空ディレクトリのため処理対象が無い）。

- [ ] **Step 6: sisimai のバージョンが 5.7.1 であることを直接確認する**

```bash
ssh pi 'bash -lc "cd ~/sisito && mise exec -- ruby -e \"require %q(bundler/setup); require %q(sisimai); puts Sisimai::VERSION\""'
```

Expected: `5.7.1`

- [ ] **Step 7: mise exec を付けない場合、意図どおり失敗することを確認する**

```bash
ssh pi 'cd ~/sisito && ruby update-sisto-db.rb /tmp/sisimai-verify-empty; echo EXIT=$?'
```

Expected: `Could not find sisimai-5.7.1 in locally installed gems.` を含むエラーが出力され、`EXIT` は 0 以外。

- [ ] **Step 8: Pi を master へ戻す**

システム sisimai にはこの時点まで一切触れていないため、master へ戻せば従来どおり（システム gem 経由）で正常に動く状態にすぐ戻る。

```bash
ssh pi 'cd ~/sisito && git checkout master && git branch --show-current && git status --short'
```

Expected: `master`。追跡ファイルに変更なし。

- [ ] **Step 9: 一時ディレクトリを削除する**

```bash
ssh pi 'rmdir /tmp/sisimai-verify-empty'
```

---

### Task 4: Issue と PR を作成し、マージする

**Files:**
- 変更なし（GitHub 操作）

**Interfaces:**
- Consumes: Task 2・3 で検証済みのブランチ
- Produces: master にマージされた変更（Task 5 が deploy する）

- [ ] **Step 1: コミット内容を確認する**

```bash
cd /home/tsuyoshi/go/src/github.com/revsystem/sisito
git --no-pager log --oneline origin/master..HEAD
```

Expected: Task 2 の1コミット（`update-sisto-db.rb` と `CLAUDE.md`）。

- [ ] **Step 2: /create-issue-pr スキルで Issue 先行の PR を作成する**

`/create-issue-pr` を実行する。Issue のテスト項目には Task 3 で実施済みの検証内容を反映する。

```
- [x] mise exec -- ruby update-sisto-db.rb <空ディレクトリ> が正常終了する
- [x] mise exec -- ruby -e "..." で Sisimai::VERSION が 5.7.1 と表示される
- [x] mise exec -- を付けない実行が Could not find sisimai-5.7.1 で失敗する
- [ ] （マージ・デプロイ後）システム sisimai アンインストール後も取り込みが正常に動く
```

最後の項目は Task 6 で実施するまで未チェックのままにする。

- [ ] **Step 3: PR をユーザーに提示してマージの可否を確認する**

CI（bundler-audit 等）が green であることを確認したうえで、ユーザーに提示する。マージは明示的な承認を得てから実行する。

---

### Task 5: 本番デプロイし、動作を確認する

**Files:**
- 変更なし（Pi へのデプロイと検証）

**Interfaces:**
- Consumes: Task 4 でマージ済みの master
- Produces: 本番の Pi で新スクリプトが実際に動いている状態（Task 6 の前提）

- [ ] **Step 1: Pi が master に戻っていることを確認する**

Task 3 Step 8 で master に戻しているはずだが、`bin/deploy.sh` の `git pull --ff-only origin master` は
現在のブランチ次第で失敗・想定外の挙動になり得るため、デプロイ前に必ず確認する。

```bash
ssh pi 'cd ~/sisito && git branch --show-current && git status --short'
```

Expected: `master`。追跡ファイルに変更なし。`master` 以外だった場合は `git checkout master` してから
次に進む。

- [ ] **Step 2: Pi を最新 master へデプロイする**

```bash
ssh pi 'bash -lc "cd ~/sisito && ./bin/deploy.sh"'
```

Expected: `Fast-forward` で今回の PR のコミットが取り込まれる。`update-sisto-db.rb` は git 管理ファイルなので bundle install 等は不要（コード変更のみ）。

- [ ] **Step 3: デプロイ後の update-sisto-db.rb がテスト時と同じ内容であることを確認する**

```bash
ssh pi 'head -8 ~/sisito/update-sisto-db.rb'
```

Expected: Task 2 Step 3 で書いた内容と一致する。

- [ ] **Step 4: 空の一時ディレクトリで再度動作確認する**

```bash
ssh pi 'mkdir -p /tmp/sisimai-verify-empty && bash -lc "cd ~/sisito && mise exec -- ruby update-sisto-db.rb /tmp/sisimai-verify-empty; echo EXIT=$?"'
```

Expected: `EXIT=0`

---

### Task 6: システム sisimai をアンインストールし、最終確認する

**Files:**
- 変更なし（Pi 上の gem 環境操作、chezmoi 反映、memory 更新）

**Interfaces:**
- Consumes: Task 5 で本番反映・動作確認済みのスクリプト
- Produces: システム gem が存在しない状態でも取り込みが動くことの確認。更新済みの chezmoi と memory（このタスクで完結）

- [ ] **Step 1: アンインストール前のシステム sisimai を確認する**

```bash
ssh pi 'gem list sisimai'
```

Expected: `sisimai (5.4.0)`

- [ ] **Step 2: システム sisimai をアンインストールする**

`-x` は実行ファイル削除確認のプロンプトを省略するオプション（sisimai は実行ファイルを持たないため通常は不要だが、非対話実行で確実に止まらないようにする）。

```bash
ssh pi 'sudo gem uninstall sisimai -x'
```

Expected: `Successfully uninstalled sisimai-5.4.0`

- [ ] **Step 3: アンインストールされたことを確認する**

```bash
ssh pi 'gem list sisimai'
```

Expected: 出力が空（`sisimai` を含む行が無い）。

- [ ] **Step 4: アンインストール後も正しい起動方法が動くことを再確認する**

一時ディレクトリが存在しない場合に備えて `mkdir -p` で再作成してから使う（再起動や `/tmp` 掃除の影響を
受けないようにする）。

```bash
ssh pi 'mkdir -p /tmp/sisimai-verify-empty && bash -lc "cd ~/sisito && mise exec -- ruby update-sisto-db.rb /tmp/sisimai-verify-empty; echo EXIT=$?"'
```

Expected: `EXIT=0`

- [ ] **Step 5: 検証用の一時ディレクトリを削除する**

```bash
ssh pi 'rmdir /tmp/sisimai-verify-empty'
```

- [ ] **Step 6: chezmoi へ SKILL.md の変更を反映する**

```bash
chezmoi re-add ~/go/src/github.com/revsystem/sisito/.claude/skills/sisito-deploy/SKILL.md
chezmoi status ~/go/src/github.com/revsystem/sisito/.claude/skills/sisito-deploy/SKILL.md
cd ~/.local/share/chezmoi
git add go/src/github.com/revsystem/sisito/dot_claude/skills/sisito-deploy/SKILL.md
git commit -m "docs(sisito-deploy): update-sisto-db.rb now uses project bundler, not system sisimai"
```

Expected: `chezmoi status` の出力が空（差分なし）。

- [ ] **Step 7: Issue の最後のテスト項目にチェックを入れる**

Task 4 で作成した Issue の最後の項目（システム sisimai アンインストール後の動作確認）にチェックを入れ、Step 2〜4 の実行結果を証跡としてコメントに残す。

- [ ] **Step 8: memory/project_pi_ingestion_arch.md を更新する**

`/home/tsuyoshi/.claude/projects/-home-tsuyoshi-go-src-github-com-revsystem-sisito/memory/project_pi_ingestion_arch.md` の「取り込みはシステム ruby + システム sisimai 5.4.0」という記述を、2026-07-21 以降は `require 'bundler/setup'` によりプロジェクトの bundle（sisimai 5.7.1）を使うこと、システム sisimai はアンインストール済みであることに更新する。

---

## 自己レビュー結果

**仕様網羅性の確認:**
- 設計の「1. 前提確認」→ Task 1 で対応。
- 設計の「2. update-sisto-db.rb」→ Task 2 Step 3 で対応。
- 設計の「運用上の注意」（旧起動習慣が即座に失敗する）→ Task 3 Step 7 で実測確認。
- 設計の「3. 起動方法」→ Task 3 Step 5-6 で検証。
- 設計の「4. CLAUDE.md の更新」→ Task 2 Step 4 で対応。
- 設計の「5. sisito-deploy スキルの更新」→ Task 2 Step 5-6、Task 6 Step 6（chezmoi 反映）で対応。
- 設計の「6. システム sisimai のアンインストール」→ Task 6 Step 1-5 で対応。
- 設計の「検証」セクション全項目 → Task 3・5・6 の各 Step にすべて対応。

**設計時点から追加した安全策:** brainstorming の設計文書には無かった「システム gem のアンインストールをマージ・デプロイ完了後まで遅らせる」という順序を、writing-plans の自己レビュー時に追加した。設計文書の「6. システム sisimai のアンインストール」の運用注記（切り替え直後は旧起動習慣が即失敗する）を素直にタスク化すると、ブランチテスト後に Pi を master へ戻すタイミングでシステム gem が既に無い状態になり得て、マージ待ちの間 Pi の取り込みが完全に壊れる時間帯が生まれることに気づいたため。Task 3 Step 8（テスト後は必ず master へ戻す。システム gem 未変更のため即座に正常復帰する）と、Task 5→Task 6 の順序（本番デプロイ確認後に初めてアンインストール）でこれを解消した。

**プレースホルダ確認:** 「TBD」「後で実装」等は無し。すべての Step に実行コマンドと期待値を明記した。

**型・命名の一貫性確認:** `update-sisto-db.rb` の変更内容（Task 2 Step 3）と Task 3 Step 6 の検証コマンド、Task 5 Step 2 の確認内容はすべて同一の2行を参照している。CLAUDE.md・SKILL.md の置換対象文字列は現状のファイル内容から実際に `grep`/`sed -n` で確認した文字列をそのまま使用した。
