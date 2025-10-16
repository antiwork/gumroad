class AddRefundCreditCardToUsers < ActiveRecord::Migration[7.0]
    def change
      add_column :users, :refund_credit_card_id, :integer, null: true
      add_foreign_key :users, :credit_cards, column: :refund_credit_card_id
    end
  end
