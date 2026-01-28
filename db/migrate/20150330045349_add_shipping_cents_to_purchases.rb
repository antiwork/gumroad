# frozen_string_literal: true

class AddShippingCentsToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :shipping_cents, :integer, default: 0
  end
end
