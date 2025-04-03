# frozen_string_literal: true

class AddShippingCentsToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :shipping_cents, :integer, default: 0
  end
end
