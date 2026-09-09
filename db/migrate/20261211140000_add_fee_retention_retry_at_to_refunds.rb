# frozen_string_literal: true

# Indexed dispatch for outstanding refund fee retention / debit retry work.
# JSON markers alone force a history scan; this nullable timestamp is set while
# work remains and cleared when retention + holding reconcile are finished.
class AddFeeRetentionRetryAtToRefunds < ActiveRecord::Migration[7.1]
  def change
    change_table :refunds, bulk: true do |t|
      t.datetime :fee_retention_retry_at, precision: nil
      t.index :fee_retention_retry_at, name: "index_refunds_on_fee_retention_retry_at"
    end
  end
end
