#!/usr/bin/env bash
# Manual deploy helper for Raspberry Pi (or any host running sisito directly,
# without docker-compose). Idempotent: safe to run repeatedly.
#
# Aborts on local uncommitted changes or non-fast-forward divergence to keep
# production state predictable. Run from anywhere; it cd's to the project root.
#
# Out of scope:
# - db:migrate is intentionally NOT run automatically. sisito has very few
#   migrations and runs on a single Pi against a large bounce_mails table,
#   so migrations should be applied manually during a maintenance window.
#   This script only WARNS when pending migrations exist.

set -euo pipefail
cd "$(dirname "$0")/.."

git fetch origin
git pull --ff-only origin master

mise install

# Persist deployment / without via bundle config so we don't rely on
# per-invocation flags (deprecated in future Bundler versions).
mise exec -- bundle config set --local deployment 'true'
mise exec -- bundle config set --local without 'development test'
mise exec -- bundle install

# SECRET_KEY_BASE_DUMMY allows boot under RAILS_ENV=production without an
# actual secret_key_base. assets:precompile only needs the environment to
# load; it does not use the secret itself.
RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 mise exec -- bundle exec rails assets:precompile

# Restart Puma via tmp/restart.txt (config/puma.rb has `plugin :tmp_restart`).
# If the server is not currently running, leave startup to the operator
# to preserve their existing screen/tmux/nohup wrapping.
if [ -f tmp/pids/server.pid ] && kill -0 "$(cat tmp/pids/server.pid)" 2>/dev/null; then
  mise exec -- bundle exec rails restart
  echo "Deploy done. Puma reloaded via tmp/restart.txt."
else
  echo "Deploy done. Rails server is not running; start it manually:"
  echo "  RAILS_ENV=production mise exec -- bundle exec rails server -p 1080 -b 0.0.0.0"
fi

# Warn (do not auto-apply) if there are pending migrations.
PENDING=$(RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 \
  mise exec -- bundle exec rails db:migrate:status 2>/dev/null \
  | awk '$1 == "down" { count++ } END { print count + 0 }')
if [ "$PENDING" -gt 0 ]; then
  echo ""
  echo "WARNING: $PENDING pending migration(s) detected. Run manually during a maintenance window:"
  echo "  RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 mise exec -- bundle exec rails db:migrate"
fi
