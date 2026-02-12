# frozen_string_literal: true

class AddUniqueIndexToCreditsRefundFundingPurchaseId < ActiveRecord::Migration[7.1]
  def change
    add_index :credits, :refund_funding_purchase_id,
              unique: true,
              where: "refund_funding_purchase_id IS NOT NULL",
              name: "index_credits_unique_refund_funding_purchase"
  end
end
