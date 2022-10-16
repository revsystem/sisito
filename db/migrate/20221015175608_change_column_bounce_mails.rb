class ChangeColumnBounceMails < ActiveRecord::Migration[5.1]
  def change
    change_column :bounce_mails, :diagnosticcode, :text, null: false
  end
end
