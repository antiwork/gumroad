# frozen_string_literal: true

class AddRefundFundingColumnsToCredits < ActiveRecord::Migration[7.1]
  def change
    add_column :credits, :refund_funding_purchase_id, :bigint
    add_column :credits, :credit_card_id, :bigint
    add_index :credits, :refund_funding_purchase_id
    add_index :credits, :credit_card_id
  end
end