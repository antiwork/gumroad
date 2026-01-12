# frozen_string_literal: true

class AddRefundFundingCreditCardToUsers < ActiveRecord::Migration[7.1]
  def change
    Alterity.disable do
      add_reference :users, :refund_funding_credit_card, type: :integer, foreign_key: { to_table: :credit_cards }, index: true
    end
  end
end
