# frozen_string_literal: true

class CreateRefundPaymentMethods < ActiveRecord::Migration[7.1]
  def change
    create_table :refund_payment_methods do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.references :credit_card, null: false, foreign_key: true, type: :integer
      t.string :cardholder_name, null: false

      t.timestamps
    end
  end
end
