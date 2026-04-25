#!/usr/bin/env bash
# Manual deploy helper for Raspberry Pi (or any host running sisito directly,
# without docker-compose). Idempotent: safe to run repeatedly.
#
# Aborts on local uncommitted changes or non-fast-forward divergence to keep
# production state predictable. Run from anywhere; it cd's to the project root.
#
# RAILS_ENV:
#   Defaults to `development` because that is how the Pi (sisito's only
#   real deployment) is actually run — see `## Important Gotchas` in
#   CLAUDE.md. Override with `RAILS_ENV=production ./bin/deploy.sh` when
#   the production: block in config/database.yml is properly configured.
#
# Out of scope:
# - db:migrate is intentionally NOT run automatically. sisito has very few
#   migrations and runs on a single Pi against a large bounce_mails table,
#   so migrations should be applied manually during a maintenance window.
#   This script only WARNS when pending migrations exist.

set -euo pipefail
cd "$(dirname "$0")/.."

: "${RAILS_ENV:=development}"
export RAILS_ENV

git fetch origin
git pull --ff-only origin master

mise install

# Persist deployment / without via bundle config so we don't rely on
# per-invocation flags (deprecated in future Bundler versions).
#
# Note: only `:test` is excluded. The `:development` group must be
# installed because the Pi runs as RAILS_ENV=development (see CLAUDE.md
# Gotcha #7), and config/environments/development.rb requires `listen`
# via `ActiveSupport::EventedFileUpdateChecker`. Excluding :development
# breaks `assets:precompile` and the server boot.
mise exec -- bundle config set --local deployment 'true'
mise exec -- bundle config set --local without 'test'
mise exec -- bundle install

# SECRET_KEY_BASE_DUMMY allows boot under RAILS_ENV=production without an
# actual secret_key_base. assets:precompile only needs the environment to
# load; it does not use the secret itself. Harmless under other envs.
SECRET_KEY_BASE_DUMMY=1 mise exec -- bundle exec rails assets:precompile

# Restart Puma via tmp/restart.txt (config/puma.rb has `plugin :tmp_restart`).
# If the server is not currently running, leave startup to the operator
# to preserve their existing screen/tmux/nohup wrapping.
if [ -f tmp/pids/server.pid ] && kill -0 "$(cat tmp/pids/server.pid)" 2>/dev/null; then
  mise exec -- bundle exec rails restart
  echo "Deploy done. Puma reloaded via tmp/restart.txt."
else
  echo "Deploy done. Rails server is not running; start it manually:"
  echo "  RAILS_ENV=$RAILS_ENV mise exec -- bundle exec rails server -p 1080 -b 0.0.0.0"
fi

# Warn (do not auto-apply) if there are pending migrations.
# Capture both streams; do NOT silently swallow connection errors etc.
# `if VAR=$(...); then` keeps `set -e` from aborting on a non-zero status.
if STATUS=$(SECRET_KEY_BASE_DUMMY=1 mise exec -- bundle exec rails db:migrate:status 2>&1); then
  PENDING=$(echo "$STATUS" | awk '$1 == "down" { count++ } END { print count + 0 }')
  if [ "$PENDING" -gt 0 ]; then
    echo ""
    echo "WARNING: $PENDING pending migration(s) detected. Run manually during a maintenance window:"
    echo "  RAILS_ENV=$RAILS_ENV mise exec -- bundle exec rails db:migrate"
  fi
else
  echo ""
  echo "WARNING: failed to query migration status (RAILS_ENV=$RAILS_ENV). Last lines:"
  echo "$STATUS" | tail -5
fi
