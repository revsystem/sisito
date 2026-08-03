# sisito デプロイスキル 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** sisito を Pi へ反映する手順と前後の条件を、プロジェクトスコープのスキルとして再現可能にする。

**Architecture:** 単一の `SKILL.md` をプロジェクトの `.claude/skills/sisito-deploy/` に置き、`.gitignore` で公開リポジトリから除外し、chezmoi で版管理する。機械的な実行は既存の `bin/deploy.sh` が担い、スキルはその前後の条件（前提チェック、Spring を止めての検証、復旧）を扱う。CLAUDE.md には不変条件を残し、手順への参照と Spring の gotcha だけ追記する。

**Tech Stack:** Markdown（SKILL.md）、git、chezmoi、ssh

## Global Constraints

- スキルは明示起動のみ。frontmatter に `disable-model-invocation: true` を必ず入れる。
- Pi 固有情報（IPアドレス、ホームディレクトリの絶対パス、鍵の運用詳細）を公開リポジトリにコミットしない。
- ローカル（WSL2）に gem を入れない。ローカルは編集専用。
- 対象リポジトリのパスは `/home/tsuyoshi/go/src/github.com/revsystem/sisito`。
- chezmoi の destDir は `/home/tsuyoshi`、sourceDir は `/home/tsuyoshi/.local/share/chezmoi`。
- コミットメッセージは英語・コンベンショナルコミット形式。セッションURLは含めない。

## File Structure

| ファイル | 責務 | 追跡 |
|---|---|---|
| `.claude/skills/sisito-deploy/SKILL.md` | デプロイ手順と条件の唯一の実体 | gitignore（chezmoi 管理） |
| `.gitignore` | `/.claude/skills/` を除外 | 追跡（コミット） |
| `CLAUDE.md` | 不変条件の保持と、手順への参照・Spring gotcha の追記 | 追跡（コミット） |

---

### Task 1: 作業ブランチを用意する

**Files:**
- Modify: なし（リポジトリ状態のみ）

**Interfaces:**
- Consumes: なし
- Produces: ブランチ `heads/add_deploy_skill`（以降の全タスクがこの上で作業する）

- [ ] **Step 1: 現在の状態を確認する**

```bash
cd /home/tsuyoshi/go/src/github.com/revsystem/sisito
git branch --show-current
git status --short
```

Expected: `heads/update_loofah_advisory` と ` M CLAUDE.md`（revise-claude-md の未コミット分）。未追跡の handover/spec/plan も出る。

- [ ] **Step 2: 最新 master を取得する**

```bash
git fetch origin
git --no-pager log --oneline -1 origin/master
```

Expected: `b8a10aa Merge pull request #24 from revsystem/heads/update_sisimai_5.7.1`（またはそれ以降）

- [ ] **Step 3: 新ブランチを作成する**

`CLAUDE.md` のコミット済み内容は両ブランチで同一なので、未コミット変更はそのまま持ち越される。

```bash
git checkout -b heads/add_deploy_skill origin/master
```

Expected: `Switched to a new branch 'heads/add_deploy_skill'`

checkout が未コミット変更との衝突で失敗した場合は `git stash push -- CLAUDE.md` で退避してから checkout し、直後に `git stash pop` で戻す。

- [ ] **Step 4: 未コミット変更が保持されたことを確認する**

```bash
git status --short
git --no-pager diff --stat -- CLAUDE.md
```

Expected: ` M CLAUDE.md` と `1 file changed, 12 insertions(+), 1 deletion(-)`

---

### Task 2: .gitignore で .claude/skills/ を除外する

**Files:**
- Modify: `/home/tsuyoshi/go/src/github.com/revsystem/sisito/.gitignore`（90 行目 `/.claude/settings.local.json` の直後）

**Interfaces:**
- Consumes: Task 1 のブランチ
- Produces: `.claude/skills/` 配下が git に追跡されない状態（Task 3 が依存する）

- [ ] **Step 1: 現状で除外が効いていないことを確認する**

```bash
cd /home/tsuyoshi/go/src/github.com/revsystem/sisito
git check-ignore -v .claude/skills/sisito-deploy/SKILL.md; echo "exit=$?"
```

Expected: 出力なしで `exit=1`（まだ除外されていない）

- [ ] **Step 2: .gitignore に1行追加する**

`/.claude/settings.local.json` の直後に追加する。

```
/.claude/settings.local.json
/.claude/skills/
```

- [ ] **Step 3: 除外が効くことを確認する**

```bash
git check-ignore -v .claude/skills/sisito-deploy/SKILL.md; echo "exit=$?"
```

Expected: `.gitignore:91:/.claude/skills/	.claude/skills/sisito-deploy/SKILL.md` と `exit=0`

- [ ] **Step 4: コミットする**

```bash
git add .gitignore
git commit -m "chore: ignore local-only .claude/skills directory"
```

Expected: 1 file changed, 1 insertion(+)

---

### Task 3: SKILL.md を作成する

**Files:**
- Create: `/home/tsuyoshi/go/src/github.com/revsystem/sisito/.claude/skills/sisito-deploy/SKILL.md`

**Interfaces:**
- Consumes: Task 2 の gitignore（このファイルがコミット対象にならないことを保証する）
- Produces: `/sisito-deploy` で起動できるスキル（Task 4 が chezmoi へ取り込む）

- [ ] **Step 1: まだ存在しないことを確認する**

```bash
cd /home/tsuyoshi/go/src/github.com/revsystem/sisito
ls -d .claude/skills/sisito-deploy 2>/dev/null; echo "exit=$?"
```

Expected: 出力なしで `exit` は非ゼロ

- [ ] **Step 2: ディレクトリを作成して SKILL.md を書く**

```bash
mkdir -p .claude/skills/sisito-deploy
```

`.claude/skills/sisito-deploy/SKILL.md` の内容は以下のとおり。

````markdown
---
name: sisito-deploy
description: sisito を Raspberry Pi へデプロイし反映を検証する。前提チェック、bin/deploy.sh の実行、Spring を止めての反映確認、失敗時の復旧を扱う。
disable-model-invocation: true
---

# sisito デプロイ

Raspberry Pi (`pi`) 上の sisito へ変更を反映し、反映されたことを検証する。
機械的な実行は `bin/deploy.sh` が担う。このスキルはその前後の条件を扱う。

## 前提（先に読む）

- ローカル（WSL2）は編集専用。gem をローカルに入れない。反映と検証は Pi 上で行う。
- Pi は `RAILS_ENV=development` で動く。bundle は deployment モードで `vendor/bundle` に入る。
- 接続は `ssh pi`（`~/.ssh/config` の Host pi、ed25519 鍵）。非対話実行のため
  パスワード認証もパスフレーズ付き鍵も使えない。必ず鍵認証を使う。
- 取り込み（`update-sisto-db.rb`）は system ruby と system sisimai で動き、bundle とは別系統。
  Gemfile の gem を上げても取り込み挙動は変わらない。

## 手順

### 1. マージ状態を確認する

`bin/deploy.sh` は `git pull --ff-only origin master` を行う。未マージのブランチは反映されない。

```bash
git fetch origin
gh pr list --state open
git --no-pager log --oneline -1 origin/master
```

未マージのものを検証だけしたい場合は、Pi でそのブランチを checkout して確認し、終わったら
master へ戻す。

### 2. Pi の作業ツリーを確認する（最重要）

```bash
ssh pi 'cd ~/sisito && git status --short && git branch --show-current'
```

追跡ファイルに未コミット変更（特に `Gemfile.lock`）があると `git pull --ff-only` が止まる。
破棄せず退避する。

```bash
ssh pi 'cd ~/sisito && git stash push -m pre-deploy-<理由> -- Gemfile.lock'
```

未追跡ファイル（`tmp_mail/`、`*.tmp` 等）は pull を妨げない。放置してよい。

### 3. デプロイを実行する

```bash
ssh pi 'bash -lc "cd ~/sisito && ./bin/deploy.sh"'
```

`bash -lc` は必須。非対話 ssh では mise が PATH に無く、`deploy.sh` 内の `mise exec` が失敗する。

`deploy.sh` は pull、mise install、bundle install（deployment・without test）、assets:precompile、
Puma 稼働時のみ再起動、未適用 migration の警告、を行う。migration は自動適用されない。
警告が出たらメンテナンス時間帯に手動で当てる。

### 4. 反映を検証する（Spring に注意）

先に Spring を止める。止めないとデプロイ前の gem 版が報告される。

```bash
ssh pi 'bash -lc "cd ~/sisito && mise exec -- bundle exec spring stop"'
```

boot と主要 gem の版を確認する。

```bash
ssh pi 'bash -lc "cd ~/sisito && DISABLE_SPRING=1 RAILS_ENV=development SECRET_KEY_BASE_DUMMY=1 mise exec -- bundle exec rails runner -"' <<'RUBY'
puts "boot OK"
%w[sisimai loofah rails-html-sanitizer].each do |g|
  s = Gem.loaded_specs[g]
  puts "  #{g}: #{s ? s.version : '(not loaded)'}"
end
RUBY
```

出力が `Gemfile.lock` の記載と一致することを確認する。

### 5. 後始末

退避した stash は用が済んだら drop する。

```bash
ssh pi 'cd ~/sisito && git stash list'
```

Puma は `deploy.sh` が自動起動しない（運用者の screen/tmux/nohup を壊さないため）。起動は原則、
運用者が Pi 上の screen/tmux 内で行う。非対話 ssh から素で起動すると rails server がフォアグラウンドで
ブロックしたまま ssh セッションに縛られ、切断時に SIGHUP で落ちる。ssh 越しに起動する必要がある場合は
nohup で切り離す。

```bash
ssh pi 'bash -lc "cd ~/sisito && nohup env RAILS_ENV=development mise exec -- bundle exec rails server -p 1080 -b 0.0.0.0 >> log/server.log 2>&1 & disown"'
```

## 詰まったとき

- `git pull --ff-only` が止まる → 手順2へ戻り、未コミット変更を stash する。
- 検証が古い gem 版を報告する → 手順4の `spring stop` を忘れている。
- `mise: command not found` → `bash -lc` で包んでいない。
- `Permission denied (publickey)` → 鍵認証が壊れている。パスワード認証は非対話では使えない。
````

- [ ] **Step 3: ファイルが存在し、git に現れないことを確認する**

```bash
ls -l .claude/skills/sisito-deploy/SKILL.md
git status --short | grep '\.claude/skills'; echo "exit=$?"
```

Expected: ファイルが存在し、grep は出力なしで `exit=1`（`.claude/skills/` が git status に現れない）

- [ ] **Step 4: frontmatter が正しいことを確認する**

```bash
head -5 .claude/skills/sisito-deploy/SKILL.md
```

Expected: `name: sisito-deploy` と `disable-model-invocation: true` を含む

---

### Task 4: chezmoi 管理下に置く

**Files:**
- Create: `/home/tsuyoshi/.local/share/chezmoi/go/src/github.com/revsystem/sisito/dot_claude/skills/sisito-deploy/SKILL.md`

**Interfaces:**
- Consumes: Task 3 の `SKILL.md`
- Produces: chezmoi 管理下のスキル（他マシンへ配布可能な状態）

- [ ] **Step 1: 現状 chezmoi 管理外であることを確認する**

```bash
chezmoi source-path ~/go/src/github.com/revsystem/sisito/.claude/skills/sisito-deploy/SKILL.md 2>&1; echo "exit=$?"
```

Expected: エラーメッセージと非ゼロの `exit`（未管理）

- [ ] **Step 2: chezmoi に取り込む**

```bash
chezmoi add ~/go/src/github.com/revsystem/sisito/.claude/skills/sisito-deploy/SKILL.md
```

- [ ] **Step 3: source path が解決し、差分が無いことを確認する**

```bash
chezmoi source-path ~/go/src/github.com/revsystem/sisito/.claude/skills/sisito-deploy/SKILL.md
chezmoi status ~/go/src/github.com/revsystem/sisito/.claude/skills/sisito-deploy/SKILL.md; echo "exit=$?"
```

Expected: source path が `/home/tsuyoshi/.local/share/chezmoi/go/src/github.com/revsystem/sisito/dot_claude/skills/sisito-deploy/SKILL.md`。`status` は出力なしで `exit=0`

- [ ] **Step 4: chezmoi source リポジトリにコミットする**

chezmoi の source は git リポジトリ `revsystem/dotfiles`（PRIVATE、確認済み）である。非公開なので Pi 固有情報を含めてよい。

```bash
cd ~/.local/share/chezmoi
git add go/src/github.com/revsystem/sisito/dot_claude/skills/sisito-deploy/SKILL.md
git commit -m "feat: add sisito-deploy skill"
```

Expected: `1 file changed, N insertions(+)`

- [ ] **Step 5: 新規マシン向けの順序制約を dotfiles README に記録する**

`chezmoi apply` を clone より先に走らせると `~/go/src/github.com/revsystem/sisito/.claude/skills/` が先に作られ、`git clone` が空でないディレクトリを拒否する。この制約を dotfiles の README（新規マシンのセットアップで最初に読む場所）に追記して commit する。

`~/.local/share/chezmoi/README.md` の末尾に追記する内容:

```markdown
## プロジェクト内パスの管理

`go/src/github.com/revsystem/sisito/` 配下は、プロジェクトリポジトリ内で gitignore された
ファイル（`.claude/skills/` 等）を chezmoi で管理している。新規マシンではプロジェクトの
`git clone` を先に行い、`chezmoi apply` はその後に実行する。逆順で apply すると clone 先が
空でなくなり `git clone` が失敗する。その場合は既存ディレクトリ上に展開する:

    cd ~/go/src/github.com/revsystem/sisito
    git init && git remote add origin https://github.com/revsystem/sisito.git
    git fetch && git checkout -f master
```

```bash
cd ~/.local/share/chezmoi
git add README.md
git commit -m "docs: note clone-before-apply constraint for project-scoped files"
```

Expected: `1 file changed, N insertions(+)`

---

### Task 5: CLAUDE.md に参照と Spring gotcha を追記する

**Files:**
- Modify: `/home/tsuyoshi/go/src/github.com/revsystem/sisito/CLAUDE.md`（Important Gotchas 節）

**Interfaces:**
- Consumes: Task 1 のブランチ（既存の未コミット CLAUDE.md 変更を含む）
- Produces: コミット済みの CLAUDE.md（Task 6 が PR にする）

- [ ] **Step 1: 現在の gotcha の末尾番号を確認する**

```bash
cd /home/tsuyoshi/go/src/github.com/revsystem/sisito
sed -n '/## Important Gotchas/,/^## /p' CLAUDE.md | grep -E '^[0-9]+\.' | tail -2
```

Expected: 末尾が `8. Sisimai `to_hash` field rename: ...`（revise-claude-md の未コミット分）

- [ ] **Step 2: gotcha #7 の末尾に参照行を追加する**

`only if the production block is properly configured first.` の直後に、同じ行の続きとして追記する。

```
 Deployment procedure, pre-checks and post-deploy verification are maintained in a local (gitignored) `.claude/skills/sisito-deploy` skill, not in this file.
```

- [ ] **Step 3: gotcha #9 を追加する**

gotcha #8 の直後に新しい行として追加する。

```
9. Spring preloader caches the app: `spring` is in the development group and the Pi runs `RAILS_ENV=development`, so a preloaded process keeps the previous app and gems in memory. After a gem change (deploy or a local bundle change) `rails` commands report stale versions until `spring stop` is run or `DISABLE_SPRING=1` is set.
```

- [ ] **Step 4: 追記結果を確認する**

```bash
sed -n '/## Important Gotchas/,/^## /p' CLAUDE.md | grep -E '^[0-9]+\.' | tail -3
grep -c 'sisito-deploy' CLAUDE.md
```

Expected: 番号が 7、8、9 と並び、`sisito-deploy` が 1 件見つかる

- [ ] **Step 5: コミットする**

```bash
git add CLAUDE.md
git commit -m "docs: document Spring preloader caching and point deploy procedure to the local skill"
```

---

### Task 6: Issue と PR を作成する

**Files:**
- Modify: なし（GitHub 上の操作）

**Interfaces:**
- Consumes: Task 2 と Task 5 のコミット
- Produces: Issue にひも付いた PR

- [ ] **Step 1: コミット内容を確認する**

```bash
cd /home/tsuyoshi/go/src/github.com/revsystem/sisito
git --no-pager log --oneline origin/master..HEAD
git status --short
```

Expected: 2 コミット（gitignore と CLAUDE.md）。`.claude/skills/` は git status に現れない。

- [ ] **Step 2: /create-issue-pr スキルで Issue 先行の PR を作成する**

`/create-issue-pr` を実行する。Issue のテスト項目には次を入れる。

```
- [ ] .claude/skills/ が git に追跡されないことを確認する（git check-ignore が exit 0）
- [ ] sisito ディレクトリでスキル一覧に sisito-deploy が出ることを確認する
- [ ] chezmoi status が空であることを確認する
```

- [ ] **Step 3: テスト項目を実測して Issue に反映する**

各項目を実行し、証跡とともに Issue のチェックを更新する。スキル一覧の確認は、スキルがセッション開始時に読み込まれるため新しいセッションで行う。

---

## 検証（全タスク完了後）

- [ ] `git check-ignore -v .claude/skills/sisito-deploy/SKILL.md` が `exit=0`
- [ ] `chezmoi status` が空
- [ ] 新しいセッションで `/sisito-deploy` が候補に出る
- [ ] CLAUDE.md の gotcha が 9 番まで並び、`sisito-deploy` への参照がある
