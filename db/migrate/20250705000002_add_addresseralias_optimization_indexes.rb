class AddAddresseraliasOptimizationIndexes < ActiveRecord::Migration[7.2]
  def up
    # addresseralias カラムの最適化専用インデックス
    
    # NULL以外のaddresseraliasでの検索用（空文字も含む）
    add_index :bounce_mails, [:addresseralias], 
              where: "addresseralias IS NOT NULL", 
              name: 'idx_addresseralias_not_null'
    
    # addresseralias + recipient の複合インデックス（DISTINCT処理用）
    add_index :bounce_mails, [:addresseralias, :recipient], 
              where: "addresseralias IS NOT NULL AND addresseralias != ''", 
              name: 'idx_addresseralias_recipient_valid'
    
    # addresser + recipient の複合インデックス（addresseralias空の場合用）
    add_index :bounce_mails, [:addresser, :recipient], 
              where: "addresseralias IS NULL OR addresseralias = ''", 
              name: 'idx_addresser_recipient_fallback'
  end

  def down
    remove_index :bounce_mails, name: 'idx_addresseralias_not_null'
    remove_index :bounce_mails, name: 'idx_addresseralias_recipient_valid'
    remove_index :bounce_mails, name: 'idx_addresser_recipient_fallback'
  end
end