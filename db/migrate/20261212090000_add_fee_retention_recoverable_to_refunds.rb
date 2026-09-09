# frozen_string_literal: true

class AddFeeRetentionRecoverableToRefunds < ActiveRecord::Migration[7.1]
  def change
    change_table :refunds, bulk: true do |t|
      t.boolean :fee_retention_recoverable, default: false, null: false
      t.index :fee_retention_recoverable, name: "index_refunds_on_fee_retention_recoverable"
    end
  end
end
