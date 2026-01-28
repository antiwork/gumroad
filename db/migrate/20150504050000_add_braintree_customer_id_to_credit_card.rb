# frozen_string_literal: true

class AddBraintreeCustomerIdToCreditCard < ActiveRecord::Migration[4.2]
  def change
    add_column :credit_cards, :braintree_customer_id, :string
  end
end
