# frozen_string_literal: true

class AddRefundFundingFieldsToCredits < ActiveRecord::Migration[7.1]
  def change
    add_column :credits, :refund_funding_purchase_id, :integer
    add_column :credits, :credit_card_id, :integer
    add_index :credits, :refund_funding_purchase_id
  end
end
