# frozen_string_literal: true

class CreateOrderPurchases < ActiveRecord::Migration[7.0]
  def change
    create_table :order_purchases do |t|
      t.references :order, null: false
      t.references :purchase, null: false

      t.timestamps
    end
  end
end
