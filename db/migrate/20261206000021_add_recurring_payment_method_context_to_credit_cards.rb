# frozen_string_literal: true

class AddRecurringPaymentMethodContextToCreditCards < ActiveRecord::Migration[7.1]
  def change
    change_table :credit_cards, bulk: true do |t|
      t.string :payment_method_type
      t.string :stripe_account_id
      t.datetime :recurring_authorization_verified_at
      t.string :recurring_authorization_currency
      t.integer :recurring_authorization_max_amount_cents
    end
  end
end
