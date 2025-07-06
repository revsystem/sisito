# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Sisito is a Ruby on Rails 7.2 web application that provides a frontend dashboard for analyzing email bounce data collected by the Sisimai library. It helps monitor email delivery issues, track blacklisted recipients, and manage email bounce analytics.

## Technology Stack

- **Framework**: Ruby on Rails 7.2.2 with explicit Sprockets configuration
- **Ruby Version**: 3.1.2+ required
- **Database**: MySQL 8.0.36+ with utf8mb3 charset, optimized for large datasets
- **Asset Pipeline**: Sprockets with Sass, CoffeeScript, and Bootstrap 3.4
- **Authentication**: Optional Google OAuth2 via OmniAuth
- **Charts**: C3.js for data visualization
- **Pagination**: Kaminari gem with performance-optimized configuration
- **Caching**: Multi-tier Rails caching for statistical data

## Common Commands

### Development Setup
```bash
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

# Access points:
# - Console: http://localhost:3000
# - Mailcatcher: http://localhost:11080
# - API: curl localhost:8080/blacklist
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

# Performance-critical migrations (applied)
# - 20250705000001_add_performance_indexes_to_bounce_mails.rb
# - 20250705000002_add_addresseralias_optimization_indexes.rb
```

## Core Architecture

### Data Models
- **BounceMail**: Primary model storing email bounce data with 20+ indexed fields including timestamp, recipient, sender, bounce reason, SMTP diagnostics
- **WhitelistMail**: Manages recipient/sender domain pairs to exclude from blacklists
- **ConfirmationMail**: Handles email confirmation processes

### Key Controllers
- **StatsController** (root `/`): Dashboard with analytics, charts, and date filtering
- **BounceMailsController** (`/bounce_mails`): Browse, search, and paginate bounce records
- **WhitelistMailsController** (`/whitelist_mails`): Manage whitelisted recipients
- **AdminController** (`/admin`): Administrative functions with download capabilities
- **StatusController** (`/status`): JSON API endpoint for monitoring

### Database Schema
- **bounce_mails**: Comprehensive bounce tracking with 11 specialized composite indexes for large dataset performance
- **whitelist_mails**: Simple recipient/sender domain exclusion pairs
- **Performance Indexes**: Strategic composite indexes covering timestamp-based queries, complex JOINs, and statistical aggregations
- **Conditional Indexing**: MySQL partial indexes with WHERE clauses for specific query patterns

## Configuration

### Main Configuration
- **config/sisito.yml**: Primary application configuration including admin credentials, SMTP settings, UI customization
- **config/database.yml**: MySQL connection settings for development/test/production
- **config/application.rb**: Rails application configuration, timezone settings

### Key Configuration Options
- Admin authentication credentials
- SMTP server settings per sender domain
- UI header links and customization
- Blacklist filtering logic
- Google OAuth2 integration
- Monitoring interval settings
- Performance optimization flags (`shorten_stats`)

### Performance Configuration Files
- **config/initializers/sisito_performance.rb**: Performance-specific settings and thresholds
- **config/initializers/kaminari_config.rb**: Pagination optimization for large datasets
- **config/database.yml**: Optimized MySQL connection settings (no deprecated `reconnect` option)

## Key Features

1. **Analytics Dashboard**: Date-range filtering, bounce statistics by reason/destination
2. **Advanced Search**: Full-text search across bounce records with multiple filters
3. **Whitelist Management**: Add/remove recipients from blacklists with domain-based rules
4. **Monitoring API**: `/status` endpoint returns JSON with bounce statistics
5. **Authentication**: Optional Google OAuth2 with domain restrictions
6. **Email Integration**: Built-in SMTP functionality for sending emails

## Data Integration

### Bounce Data Collection
The application expects bounce data to be populated via external scripts using the Sisimai library. See README.md for complete Ruby script example that processes mailbox files and inserts bounce records.

### Blacklist Query Pattern
```sql
SELECT recipient FROM bounce_mails bm 
LEFT JOIN whitelist_mails wm ON bm.recipient = wm.recipient AND bm.senderdomain = wm.senderdomain
WHERE bm.senderdomain = 'example.com' AND wm.id IS NULL
```

## Performance Optimization Patterns

### Large Dataset Handling
- **Query Splitting**: Heavy statistical queries split into separate operations to avoid expensive CASE statements
- **Progressive Caching**: Multi-tier caching with 30-minute cache for recent data, 4-6 hour cache for statistical aggregations
- **Result Limiting**: Complex queries limited to top 1000 results to prevent memory issues
- **Pagination Optimization**: Kaminari configured with 20 items per page and max 1000 pages for stability

### Rails 7.2 Specific Patterns
- **Arel.sql Usage**: All raw SQL wrapped in `Arel.sql()` for Rails 7.2 security compliance
- **Explicit Sprockets**: Asset pipeline requires explicit Sprockets configuration in Rails 7.2
- **Migration Versioning**: All performance migrations use `ActiveRecord::Migration[7.2]`

### Query Optimization Strategies
- **Composite Indexing**: Strategic indexes like `(timestamp, addresser)`, `(recipient, senderdomain, timestamp)`
- **Conditional WHERE Clauses**: `WHERE addresseralias IS NOT NULL AND addresseralias != ''` instead of Rails `.where.not()`
- **SELECT Optimization**: Use `.select()` to limit column fetching in large result sets
- **DISTINCT Handling**: Split complex DISTINCT operations into simpler indexed queries

### Cache Architecture
- **Hierarchical Caching**: Different expiration times based on data volatility
- **Emergency Bypass**: `shorten_stats: true` configuration disables heavy queries during performance issues
- **Granular Keys**: Cache keys include date ranges and filters for precise invalidation
- **Production-Only**: Caching disabled in development for simplicity

## Development Patterns

### Asset Pipeline
- Uses Sprockets with Sass and CoffeeScript
- Bootstrap 3.4 for UI components
- C3.js for chart rendering
- jQuery for DOM manipulation

### Testing Structure
- Minimal test coverage using Rails default testing framework
- Tests located in `test/` directory with controllers, models, helpers
- Use `bundle exec rails test` for running tests

### Database Queries
- Extensive use of ActiveRecord with optimized queries for large datasets
- Custom SQL for complex bounce analytics with `Arel.sql()` wrapping
- Proper indexing on frequently queried fields with composite strategies

## Deployment Considerations

### Database Requirements
- MySQL 8.0.36+ with utf8mb3 charset required
- Performance optimized for datasets with 100K+ records
- Regular `OPTIMIZE TABLE bounce_mails` and `ANALYZE TABLE bounce_mails` maintenance recommended

### Performance Monitoring
- Monitor `/status` endpoint for application health
- Use `SHOW FULL PROCESSLIST` to identify slow queries
- Watch for "Creating sort index" status indicating heavy queries
- Emergency `shorten_stats: true` configuration available for performance crises

### Cache Configuration
- Production caching essential for large datasets (multi-tier strategy implemented)
- Configure proper cache store (Redis recommended for production)
- Monitor cache hit ratios for statistical queries

### Infrastructure Considerations
- Read replicas recommended for heavy analytical workloads
- Consider data archiving strategy for datasets exceeding 1M records
- Configure timezone settings in config/application.rb for local time display

### Key Performance Metrics
- Statistical dashboard: Target <8 seconds load time
- Search results: Target <5 seconds response time
- Pagination: Target <2 seconds per page