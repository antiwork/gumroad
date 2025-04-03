# frozen_string_literal: true

class AddIndexOnCartsOrderId < ActiveRecord::Migration[7.1]
  def change
    add_index :carts, :order_id
  end
end
