class AddPerformanceIndexesToBounceMails < ActiveRecord::Migration[7.2]
  def up
    # 複合インデックスを追加してパフォーマンスを改善
    
    # StatsController での日付範囲クエリ用
    add_index :bounce_mails, [:timestamp, :addresser], name: 'idx_timestamp_addresser'
    add_index :bounce_mails, [:addresser, :timestamp], name: 'idx_addresser_timestamp'
    
    # バウンス理由での検索用
    add_index :bounce_mails, [:reason, :timestamp], name: 'idx_reason_timestamp'
    
    # BounceMailsController での複雑なクエリ用
    add_index :bounce_mails, [:recipient, :senderdomain, :timestamp], name: 'idx_recipient_senderdomain_timestamp'
    
    # 検索フィルタ用複合インデックス
    add_index :bounce_mails, [:addresser, :reason, :timestamp], name: 'idx_addresser_reason_timestamp'
    
    # JOIN処理の最適化用
    add_index :bounce_mails, [:recipient, :senderdomain], name: 'idx_recipient_senderdomain_join'
    
    # hardbounce + timestamp での検索用
    add_index :bounce_mails, [:hardbounce, :timestamp], name: 'idx_hardbounce_timestamp'
    
    # destination + timestamp での統計用
    add_index :bounce_mails, [:destination, :timestamp], name: 'idx_destination_timestamp'
    
    # addresseralias での統計用
    add_index :bounce_mails, [:addresseralias], name: 'idx_addresseralias'
    
    # addresser + recipient での統計用
    add_index :bounce_mails, [:addresser, :recipient], name: 'idx_addresser_recipient'
    
    # reason + destination での複合GROUP BY用
    add_index :bounce_mails, [:reason, :destination], name: 'idx_reason_destination'
  end

  def down
    remove_index :bounce_mails, name: 'idx_timestamp_addresser'
    remove_index :bounce_mails, name: 'idx_addresser_timestamp'
    remove_index :bounce_mails, name: 'idx_reason_timestamp'
    remove_index :bounce_mails, name: 'idx_recipient_senderdomain_timestamp'
    remove_index :bounce_mails, name: 'idx_addresser_reason_timestamp'
    remove_index :bounce_mails, name: 'idx_recipient_senderdomain_join'
    remove_index :bounce_mails, name: 'idx_hardbounce_timestamp'
    remove_index :bounce_mails, name: 'idx_destination_timestamp'
    remove_index :bounce_mails, name: 'idx_addresseralias'
    remove_index :bounce_mails, name: 'idx_addresser_recipient'
    remove_index :bounce_mails, name: 'idx_reason_destination'
  end
end