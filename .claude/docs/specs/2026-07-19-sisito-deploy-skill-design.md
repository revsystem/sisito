# sisito デプロイスキル 設計

日付: 2026-07-19
状態: 設計承認済み（実装計画へ）

## 目的

sisito を Raspberry Pi へ反映する手順と、その前後の条件を言語化して再現可能にする。

2026-07-19 のセッションで、非自明な条件を手探りで再発見した。Spring がデプロイ前の gem をキャッシュして古い版を報告する、Pi の未コミット `Gemfile.lock` が `git pull --ff-only` を止める、非対話 ssh では mise が PATH に無く `bash -lc` が要る、取り込みは bundle とは別系統の system sisimai で動く、といった条件である。これらは口伝で失われるため、次回以降の再発見を防ぐ。

## スコープ

含む。デプロイの実行と事後検証。具体的には前提チェック、`bin/deploy.sh` の実行、Spring を止めての反映確認、失敗時の復旧。

含まない。依存更新の上流ワークフロー（lockfile 更新、Issue/PR 作成、マージ順の判断）は `/create-issue-pr` と既存運用に委ねる。取り込み（`update-sisto-db.rb`）の実行手順も対象外。ただし「取り込みは別系統であり Gemfile の gem を上げても挙動は変わらない」という注意だけは1行入れる。誤解しやすいため。

## 配置と配布

- 実体: `~/go/src/github.com/revsystem/sisito/.claude/skills/sisito-deploy/SKILL.md`（プロジェクトスコープ）
- chezmoi source: `~/.local/share/chezmoi/go/src/github.com/revsystem/sisito/dot_claude/skills/sisito-deploy/SKILL.md`
- `.gitignore` に `/.claude/skills/` を追加する
- 起動: 明示のみ（`disable-model-invocation: true`）。`/sisito-deploy` で起動する

理由。プロジェクトスコープに置くことで sisito で作業しているときだけ候補に出る。グローバル配置では全プロジェクトの一覧に出てしまう。gitignore により Pi 固有情報（IP、鍵、ホストパス）を公開リポジトリへ出さない。chezmoi 管理により版管理とバックアップを確保する。

運用上の注意。新規マシンでは clone を先に行う。`chezmoi apply` が先だと `.claude/skills/` が作られ、`git clone` が空でないディレクトリを拒否する。ぶつかった場合は `git init && git remote add origin <url> && git fetch && git checkout -f master` で既存ディレクトリ上に展開する。

## 構造

単一の `SKILL.md`（既存 handover と同形式）。assets 分割やスクリプト化は行わない。

理由。手順が直線的で規模が中程度に収まること、価値の中心がツール化ではなく条件の言語化にあること、機械的な実行は既に `bin/deploy.sh` が担っておりスキルはそれを置き換えず包む位置づけであること。将来トラブルシュート事例が増えて肥大化したら assets 分割へ移行する。

## 手順（6段）

1. 前提の確認（読むだけ）。ローカルは編集専用で gem を入れない。反映と検証は Pi 上で行う。Pi は `RAILS_ENV=development` で、bundle は deployment モード（`vendor/bundle`）。接続は `ssh pi`（`~/.ssh/config` の Host pi、ed25519 鍵）。非対話実行のためパスワード認証もパスフレーズ付き鍵も使えない。

2. マージ状態の確認。反映したい変更が master にマージ済みか確認する。`bin/deploy.sh` は `git pull --ff-only origin master` を行うため、未マージのブランチは反映されない。未マージのものを検証だけしたい場合は、Pi でそのブランチを checkout して確認し、終わったら master へ戻す。

3. Pi の作業ツリー確認（最重要の前提チェック）。`ssh pi 'cd ~/sisito && git status --short && git branch --show-current'` を実行する。追跡ファイルに未コミット変更（特に `Gemfile.lock`）があると pull が止まる。破棄せず `git stash push -m <理由> -- <file>` で退避してから進める。未追跡ファイル（`tmp_mail/` 等）は pull を妨げないので放置してよい。

4. デプロイ実行。`ssh pi 'bash -lc "cd ~/sisito && ./bin/deploy.sh"'` を実行する。`bash -lc` は必須で、非対話 ssh では mise が PATH に無く `deploy.sh` 内の `mise exec` が失敗するため。`deploy.sh` は pull、mise install、bundle install（deployment・without test）、assets:precompile、Puma 稼働時のみ再起動、未適用 migration の警告、を行う。migration は自動適用されないので、警告が出たらメンテナンス時間帯に手動で当てる。

5. 反映の検証。先に `mise exec -- bundle exec spring stop` を実行する。Spring はデプロイ前のアプリと gem をメモリに保持しており、止めないと古い版が報告される。そのうえで `DISABLE_SPRING=1 RAILS_ENV=development SECRET_KEY_BASE_DUMMY=1 mise exec -- bundle exec rails runner` で boot と主要 gem の版を出力し、`Gemfile.lock` の記載と一致することを確認する。

6. 後始末と復旧。退避した stash は用が済んだら drop する。Puma は `deploy.sh` が自動起動しない（運用者の screen/tmux/nohup を壊さないため）ので、必要なら `RAILS_ENV=development mise exec -- bundle exec rails server -p 1080 -b 0.0.0.0` で手動起動する。検証で古い版が出たら 5 段目の `spring stop` の失念を疑う。pull が止まったら 3 段目へ戻る。

## CLAUDE.md 側の変更

現状の CLAUDE.md にはデプロイ手順そのものが存在しない。デプロイ関連の記述は「Local Environment Constraints」節、Docker 表の1行、gotcha #7 のみである。したがって本作業は既存記述の移動ではなく、大半が新規の書き起こしとなり、CLAUDE.md 側の差分は小さい。

前提。CLAUDE.md には現在このセッション由来の未コミット変更（sisimai の `~> 5.7` 修正と gotcha #8、および Local Environment Constraints 節）がある。以下の追加はその上に積む。gotcha 番号は #9 となる。

- 「Local Environment Constraints」節は変更しない。デプロイ以外の作業にも効く不変条件であり、スキルへ移すと非デプロイ作業時に歯止めが効かなくなるため。
- gotcha #7 も本体は変更しない。環境の前提説明として残す。
- gotcha #7 の末尾に次の1行を追加する（ファイル全体が英語のため英語で書く）。

  > Deployment procedure, pre-checks and post-deploy verification are maintained in a local (gitignored) `.claude/skills/sisito-deploy` skill, not in this file.

- Spring のキャッシュに関する gotcha を #9 として新規追加する。文面は次のとおり。ローカルで gem を差し替えた場合にも影響するため、リポジトリ全体の落とし穴として公開側にも置く。運用してみて不要と判断すれば外す。

  > 9. Spring preloader caches the app: `spring` is in the development group and the Pi runs `RAILS_ENV=development`, so a preloaded process keeps the previous app and gems in memory. After a gem change (deploy or a local bundle change) `rails` commands report stale versions until `spring stop` is run or `DISABLE_SPRING=1` is set.

## 検証

作成後、sisito ディレクトリでスキル一覧に `sisito-deploy` が出ることを確認する。プロジェクトスコープのスキルが期待どおり検出されることの裏取りを兼ねる。

## 関連

- `bin/deploy.sh`（実行の実体。スキルはこれを包む）
- `.claude/handovers/2026-07-19_2147.md`（本設計の背景となった条件の一次記録）
- memory: `project_pi_ingestion_arch`、`reference_pi_ssh_access`
