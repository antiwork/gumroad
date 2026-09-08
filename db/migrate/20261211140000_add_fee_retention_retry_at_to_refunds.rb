# frozen_string_literal: true

# Indexed dispatch for outstanding refund fee retention / debit retry work.
# JSON markers alone force a history scan; this nullable timestamp is set while
# work remains and cleared when retention + holding reconcile are finished.
class AddFeeRetentionRetryAtToRefunds < ActiveRecord::Migration[7.1]
  def change
    add_column :refunds, :fee_retention_retry_at, :datetime, precision: nil
    add_index :refunds, :fee_retention_retry_at, name: "index_refunds_on_fee_retention_retry_at"
  end
end
