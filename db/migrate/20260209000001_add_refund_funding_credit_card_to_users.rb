# frozen_string_literal: true

class AddRefundFundingCreditCardToUsers < ActiveRecord::Migration[7.1]
  def change
    add_reference :users, :refund_funding_credit_card, type: :integer, index: true
  end
end