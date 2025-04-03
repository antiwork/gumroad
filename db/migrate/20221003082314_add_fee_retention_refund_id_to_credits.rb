# frozen_string_literal: true

class AddFeeRetentionRefundIdToCredits < ActiveRecord::Migration[6.1]
  def change
    add_column :credits, :fee_retention_refund_id, :integer
  end
end
