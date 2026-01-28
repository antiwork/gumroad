# frozen_string_literal: true

class AddStripeTransferIdIndexOnPayments < ActiveRecord::Migration[4.2]
  def change
    add_index :payments, :stripe_transfer_id
  end
end
