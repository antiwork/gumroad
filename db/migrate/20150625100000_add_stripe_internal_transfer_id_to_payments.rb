# frozen_string_literal: true

class AddStripeInternalTransferIdToPayments < ActiveRecord::Migration
  def change
    add_column :payments, :stripe_internal_transfer_id, :string
  end
end
