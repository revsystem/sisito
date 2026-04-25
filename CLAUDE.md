# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Sisito is a Ruby on Rails 7.2 web application that provides a frontend dashboard for analyzing email bounce data collected by the Sisimai library. It helps monitor email delivery issues, track blacklisted recipients, and manage email bounce analytics.

**Note:** Despite residing under a Go workspace path (`go/src/github.com/...`), this is a pure Ruby on Rails project with no Go source code. The companion `sisito-api` (Go binary) is built from a separate repository and pulled as a pre-built binary in Docker.

## Technology Stack

- **Framework**: Ruby on Rails ~> 7.2 (currently 7.2.3.1) with explicit Sprockets configuration
- **Ruby Version**: 3.4.9 (managed via `mise.toml`; Node 22 also pinned for ExecJS)
- **App Server**: Puma
- **Database**: MySQL 8.0+ with utf8mb3 charset
- **Asset Pipeline**: Sprockets 4 with dartsass-sprockets, Terser (JS), and Bootstrap 3.4
- **Authentication**: HTTP Digest for admin access; optional Google OAuth2 via OmniAuth
- **Charts**: C3.js for data visualization
- **Pagination**: Kaminari (20 per page, max 1000 pages)
- **Health Check**: `Rack::Health` middleware (mounted in `config.ru`)
- **Bounce Parsing**: Sisimai gem ~> 5.6

## Common Commands

### Development Setup
```bash
# Install Ruby/Node via mise (see mise.toml)
mise install

# Install dependencies
bundle install

# Database setup
bundle exec rails db:create db:migrate

# Start development server
bundle exec rails server

# Start server accessible from external IP
bundle exec rails server -p 1080 -b 0.0.0.0
```

### Docker Development
```bash
# Build and start containers
docker-compose build
docker-compose up

# Services:
# - Sisito (Rails): http://localhost:3000
# - Mailcatcher: http://localhost:11080
# - sisito-api (Go): curl localhost:8080/blacklist
# - MySQL, Postfix (bounce collection)
```

### Testing
```bash
# Run all tests
bundle exec rails test

# Run specific test file
bundle exec rails test test/controllers/status_controller_test.rb

# Run with verbose output
bundle exec rails test --verbose
```

### Database Operations
```bash
# Create and migrate database
bundle exec rails db:create db:migrate

# Reset database
bundle exec rails db:drop db:create db:migrate

# Generate migration
bundle exec rails generate migration MigrationName

# Check migration status
bundle exec rails db:migrate:status
```

## Core Architecture

### Data Models
- **BounceMail** (`ApplicationRecord`): Primary model for email bounce data with timestamp, recipient, sender, bounce reason, SMTP diagnostics, etc.
- **WhitelistMail** (`ApplicationRecord`): Recipient/sender domain pairs excluded from blacklists. Has `has_many :bounce_mails` via `recipient` foreign key.
- **ConfirmationMail** (`ActiveModel::Model`, no DB table): Form object for sending confirmation emails via SMTP.

### Controllers
- **StatsController** (root `/`): Dashboard with cached analytics, charts, and date/addresser filtering
- **BounceMailsController** (`/bounce_mails`): Browse, search (by email/digest), paginate bounce records with LEFT JOIN to whitelist
- **WhitelistMailsController** (`/whitelist_mails`): Register/deregister whitelisted recipients
- **AdminController** (`/admin`): Administrative functions with search and download capabilities
- **StatusController** (`/status`): JSON monitoring endpoint with bounce count statistics
- **SenderController** (`/sender`): Compose and send confirmation emails via configured SMTP
- **SessionsController** (`/auth/:provider/callback`): Google OAuth2 callback handling

### Database Schema (bounce_mails, whitelist_mails)
- Current `db/schema.rb` is at version `2026_04_25_000001` (ActiveRecord::Schema[7.2])
- Three performance index migrations are reflected in `schema.rb`:
  - `20250705000001_add_performance_indexes_to_bounce_mails` — original revision that added 11 composite indexes (kept as-is for history; most of these are dropped by the cleanup migration below)
  - `20250705000002_add_addresseralias_optimization_indexes` — original revision that added 3 partial indexes (`where: ...`); MySQL silently drops the predicate so these became plain BTREE indexes that duplicate two of the 20250705000001 indexes
  - `20260425000001_cleanup_redundant_performance_indexes` — **idempotent** cleanup that drops the 10 redundant/unused indexes from the two migrations above and ensures the 4 indexes that the controllers actually use exist (`idx_timestamp_addresser`, `idx_reason_timestamp`, `idx_recipient_senderdomain_timestamp`, `idx_reason_destination`). Safe to run on hosts where the earlier migrations were applied (full set), partially cleaned up by hand (the Pi case), or never applied at all

## Configuration

### Main Configuration
- **config/sisito.yml**: Admin credentials, SMTP settings per sender domain, UI header links, bounce filtering, digest algorithm, optional OAuth/status settings
- **config/database.yml**: MySQL connection settings with TRADITIONAL sql_mode
- **config/initializers/sisito.rb**: Loads sisito.yml, resolves secret_file, validates whitelist callback scripts, **`eval`s `blacklisted_label_filter`** from YAML
- **config/initializers/sisimai.rb**: Loads Sisimai reason keys for validation
- **config/initializers/kaminari_config.rb**: Pagination tuning (20/page, max 1000 pages)
- **config/initializers/sisito_performance.rb**: Query timeout (30s), fast stats flag, large data threshold (100K)

### Key Configuration Options (sisito.yml)
- `admin.username` / `admin.password` (or `admin.secret_file` for external YAML)
- `smtp`: Per-sender SMTP server settings
- `header_links`: Custom navigation links
- `blacklisted_label_filter`: Ruby proc (evaluated via `eval`) for filtering blacklist display
- `shorten_stats`: When true, skips heavy aggregate queries on dashboard
- `whitelist_callback.whitelisted` / `.unwhitelisted`: External script paths
- `omniauth.google_client_id` / `google_client_secret` / `hd` / `allow_users`
- `status.interval`: Monitoring interval in seconds (default 60)

## Caching Strategy

Caching is active in production only (via `cache_if_production` helper in `ApplicationController`):
- **15-minute expiry**: Date-range statistics (`count_by_date`, `count_by_destination`, `count_by_reason`, `count_by_date_reason`)
- **2-hour expiry**: Heavy aggregate queries (`uniq_count_by_destination`, `uniq_count_by_reason`, `uniq_count_by_sender`, `bounced_by_type`)
- **Status cache**: Cached for `interval - 5` seconds
- Cache keys include filter parameters (date range, addresser) for granular invalidation
- `shorten_stats: true` skips the 2-hour aggregate queries entirely (emergency bypass)

## Data Integration

### Bounce Data Collection
Bounce data is populated via external scripts using the Sisimai library. The Docker setup includes a Postfix container that collects bounces and writes them to MySQL. See README.md for the Ruby script example.

### Blacklist Query Pattern
```sql
SELECT recipient FROM bounce_mails bm
LEFT JOIN whitelist_mails wm ON bm.recipient = wm.recipient AND bm.senderdomain = wm.senderdomain
WHERE bm.senderdomain = 'example.com' AND wm.id IS NULL
```

## Utility Scripts

These scripts live at the repository root (not under `bin/`) and are invoked manually rather than through Rails tasks. README.md documents the operational usage; the notes here cover what each one does and how it relates to the rest of the codebase.

### `update-sisto-db.rb`
Sisimai-based bounce ingestion script. Reads bounce emails from a Maildir-style directory (passed as the first argv), parses them with `Sisimai.rise`, and inserts each result into `bounce_mails`. Connects directly to MySQL (`bounce` / `bounce` / `sisito_development`) without going through ActiveRecord, so timestamps are stored via `FROM_UNIXTIME(...)` and the `digest` column is populated with `SHA1(recipient)`. The Postfix container's `/collect.rb` is a similar in-container variant.

```bash
ruby update-sisto-db.rb /var/spool/sisito/mail
```

### `monitor_performance.rb`
Standalone MySQL performance monitor. Reports running queries (>5s), table size and index ratio for `bounce_mails`, presence of the four performance indexes left after the cleanup migration `20260425000001` (`idx_timestamp_addresser`, `idx_reason_timestamp`, `idx_recipient_senderdomain_timestamp`, `idx_reason_destination`), and key InnoDB memory variables (`innodb_buffer_pool_size`, `tmp_table_size`, `sort_buffer_size`). Runs against `sisito_development` by default — edit the connection block when targeting other environments.

```bash
ruby monitor_performance.rb
```

### `mysql_optimization.cnf`
Production MySQL/MariaDB tuning preset. Copy to `/etc/mysql/mysql.conf.d/sisito_optimization.cnf` (MySQL) or `/etc/mysql/mariadb.conf.d/sisito_optimization.cnf` (MariaDB) and restart the server. Tuned for bounce aggregation workloads: 2 GB `innodb_buffer_pool_size`, 1 GB `tmp_table_size`, 512 MB query cache, slow query log enabled at 5 s. Adjust `innodb_buffer_pool_size` to ~70–80% of available RAM before applying.

## Docker Composition

`docker-compose.yml` orchestrates four services. Three of them have their own Dockerfile at the repository root; MySQL uses an upstream image directly.

| Service      | Dockerfile              | Base image              | Role |
|--------------|-------------------------|-------------------------|------|
| `sisito`     | `Dockerfile.sisito`     | `ubuntu:jammy-20221003` | Rails app (Puma). Runs `bundle install --deployment`, then `migrate.sh` → `init.sh` via `entrykit` + `dumb-init`. Timezone forced to Asia/Tokyo. SMTP port rewritten 25 → 1025 to point at Mailcatcher. |
| `sisito_api` | `Dockerfile.sisito-api` | `alpine`                | Go binary `sisito-api`, downloaded pre-built from `winebarrel/sisito-api` GitHub Releases (version pinned via the `SISITO_API_VERSION` ARG). Serves `/blacklist` and related JSON endpoints on :8080. |
| `postfix`    | `Dockerfile.postfix`    | `ubuntu:jammy-20221003` | Bounce-receiving Postfix + `sisimai` + `mysql2`. The container-internal `/collect.rb` parses incoming bounces and inserts them into the shared MySQL. |
| `mysql`      | (image: `mysql:8.0.32`) | —                       | Shared database. `MYSQL_ALLOW_EMPTY_PASSWORD=1`, TZ=Asia/Tokyo. |

Mailcatcher's web UI is exposed on host port `11080` from the `sisito` container (port `1080` inside).

## Development Patterns

### Code Style
- Standard Rails conventions; **no RuboCop** configured
- All raw SQL wrapped in `Arel.sql()` for Rails 7.2 compliance
- Config access via `Rails.application.config.sisito` with `.fetch` / `.dig`
- HTTP Digest authentication (not Basic) for admin-protected views
- Known typo: `set_pervious_url` (should be `previous`) — used consistently for session key

### Asset Pipeline
- Sprockets 4 with dartsass-sprockets (replaced sass-rails/sassc-rails)
- Terser for JS minification (replaced uglifier for ES6+ support)
- Bootstrap 3.4 via `bootstrap-sass` gem
- jQuery, C3.js, Moment.js, clipboard.js
- CoffeeScript has been removed; vanilla JS used

### Testing
- **Framework**: Rails default Minitest
- **Coverage**: Minimal — only `test/controllers/status_controller_test.rb` exists
- **Known issue**: Test file defines `MonitorControllerTest` using `monitor_index_url`, but no `monitor` route exists in `config/routes.rb`. The test is stale and will fail.
- Fixtures directory exists but contains no fixture files

### CI/CD
- **GitHub Actions**: `bundler-audit` workflow only (push to `master`, PRs, weekly cron)
- **No test CI workflow** — tests are not run automatically
- **Default branch**: `master`

## Important Gotchas

1. **`eval` in initializer**: `config/initializers/sisito.rb` uses `eval()` on the `blacklisted_label_filter` YAML value — never accept untrusted YAML
2. **MySQL ignores partial indexes**: `add_index ..., where: ...` in Rails compiles to plain `CREATE INDEX` on MySQL (the `WHERE` predicate is silently dropped). Migration `20250705000002` was written under the assumption it would be honored; the resulting full indexes ended up duplicating two of the `20250705000001` indexes, which is why `20260425000001` cleans them up
3. **Stale test**: The only controller test references a non-existent route — needs to be fixed before adding test CI
4. **Session typo**: `session[:pervious_url]` is used throughout — changing it would require updating all references
5. **No Makefile**: Use `bundle exec rails` and `docker-compose` commands directly
6. **Current branch**: `heads/Rails_v7.2.3.1` — `master` is the default/production branch
7. **Pi runs as `RAILS_ENV=development`**: The actual Raspberry Pi deployment (sisito's only real production host) runs with `RAILS_ENV=development` against the `sisito_development` MySQL database — that is also why `monitor_performance.rb` hardcodes `database: 'sisito_development'`. The `production:` block in `config/database.yml` references a non-existent `sisito_production` and uses `root` with no password, so it is **not used in practice**. `bin/deploy.sh` defaults `RAILS_ENV` to `development` to match this; override with `RAILS_ENV=production ./bin/deploy.sh` only if the production block is properly configured first.
