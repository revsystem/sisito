#!/usr/bin/env bash
# Manual deploy helper for Raspberry Pi (or any host running sisito directly,
# without docker-compose). Idempotent: safe to run repeatedly.
#
# Aborts on local uncommitted changes or non-fast-forward divergence to keep
# production state predictable. Run from anywhere; it cd's to the project root.

set -euo pipefail
cd "$(dirname "$0")/.."

git fetch origin
git pull --ff-only origin master

mise install
mise exec -- bundle install --deployment --without development test

RAILS_ENV=production mise exec -- bundle exec rails db:migrate
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
