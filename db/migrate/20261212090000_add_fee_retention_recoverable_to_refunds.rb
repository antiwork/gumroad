# frozen_string_literal: true

class AddFeeRetentionRecoverableToRefunds < ActiveRecord::Migration[7.1]
  def change
    add_column :refunds, :fee_retention_recoverable, :boolean, default: false, null: false
    add_index :refunds, :fee_retention_recoverable, name: "index_refunds_on_fee_retention_recoverable"
  end
end
