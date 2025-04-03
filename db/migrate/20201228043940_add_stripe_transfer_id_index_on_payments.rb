# frozen_string_literal: true

class AddStripeTransferIdIndexOnPayments < ActiveRecord::Migration[6.0]
  def change
    add_index :payments, :stripe_transfer_id
  end
end
