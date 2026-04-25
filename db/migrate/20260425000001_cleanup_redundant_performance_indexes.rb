class CleanupRedundantPerformanceIndexes < ActiveRecord::Migration[7.2]
  # The two `20250705` performance index migrations together added 14
  # composite indexes to bounce_mails. Reviewing the queries in
  # app/controllers (StatsController, BounceMailsController, AdminController,
  # WhitelistMailsController) showed that only 4 of those 14 are actually
  # used; the other 10 are either redundant with an existing prefix index
  # already in db/schema.rb, or referenced from no query at all.
  #
  # MySQL 8 does not support partial indexes (the `WHERE` predicate in
  # `add_index ..., where: ...` is silently dropped at CREATE INDEX time),
  # so the 3 partial indexes added by 20250705000002 ended up as plain
  # BTREE indexes that duplicated 2 of the 20250705000001 indexes. That is
  # why this migration removes both the original-name and the partial-name
  # variants under `if_exists: true`.
  #
  # Kept indexes (verified against actual queries):
  #   * idx_timestamp_addresser              StatsController date range +
  #                                          addresser filter
  #   * idx_reason_timestamp                 BounceMailsController /
  #                                          AdminController reason filter
  #   * idx_recipient_senderdomain_timestamp History pages
  #                                          (BounceMailsController#show,
  #                                           AdminController#show,
  #                                           WhitelistMailsController#show)
  #   * idx_reason_destination               StatsController#bounced_by_type
  #
  # The up step is intentionally idempotent (`if_exists` / `if_not_exists`)
  # so it can converge regardless of which subset of indexes happens to
  # exist on a given host (e.g. on the Pi, idx_addresseralias,
  # idx_addresser_recipient, and idx_reason_destination had already been
  # dropped manually at some point in the past).
  REDUNDANT_INDEX_NAMES = %w[
    idx_addresser_timestamp
    idx_addresser_reason_timestamp
    idx_recipient_senderdomain_join
    idx_hardbounce_timestamp
    idx_destination_timestamp
    idx_addresseralias
    idx_addresseralias_not_null
    idx_addresseralias_recipient_valid
    idx_addresser_recipient
    idx_addresser_recipient_fallback
  ].freeze

  KEPT_INDEXES = [
    [[:timestamp, :addresser],                'idx_timestamp_addresser'],
    [[:reason, :timestamp],                   'idx_reason_timestamp'],
    [[:recipient, :senderdomain, :timestamp], 'idx_recipient_senderdomain_timestamp'],
    [[:reason, :destination],                 'idx_reason_destination']
  ].freeze

  def up
    REDUNDANT_INDEX_NAMES.each do |name|
      remove_index :bounce_mails, name: name, if_exists: true
    end

    KEPT_INDEXES.each do |columns, name|
      add_index :bounce_mails, columns, name: name, if_not_exists: true
    end
  end

  def down
    # Reversing this migration would mean recreating the 10 dropped
    # indexes that were never used and (for the partial ones) cannot be
    # reproduced under MySQL anyway. Refuse rather than silently produce
    # a different state.
    raise ActiveRecord::IrreversibleMigration
  end
end
