# frozen_string_literal: true

class AddStripeErrorCodeToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :stripe_error_code, :string
  end
end
