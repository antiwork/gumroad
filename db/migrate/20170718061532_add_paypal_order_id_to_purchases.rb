# frozen_string_literal: true

class AddPaypalOrderIdToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :paypal_order_id, :string

    add_index :purchases, :paypal_order_id
  end
end
