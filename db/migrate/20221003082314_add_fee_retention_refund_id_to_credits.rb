# frozen_string_literal: true

class AddFeeRetentionRefundIdToCredits < ActiveRecord::Migration[4.2]
  def change
    add_column :credits, :fee_retention_refund_id, :integer
  end
end
