# frozen_string_literal: true

class AddRefundFundingCreditCardToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :refund_funding_credit_card_id, :integer
    add_index :users, :refund_funding_credit_card_id
  end
end
