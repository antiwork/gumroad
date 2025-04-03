# frozen_string_literal: true

class AddStripeIdsToPayments < ActiveRecord::Migration
  def change
    add_column :payments, :stripe_connect_account_id, :string
    add_column :payments, :stripe_transfer_id, :string
  end
end
