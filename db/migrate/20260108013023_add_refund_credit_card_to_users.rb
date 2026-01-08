# frozen_string_literal: true

class AddRefundCreditCardToUsers < ActiveRecord::Migration[7.0]
  def change
    add_column :users, :refund_credit_card_id, :integer
    add_index :users, :refund_credit_card_id
  end
end
