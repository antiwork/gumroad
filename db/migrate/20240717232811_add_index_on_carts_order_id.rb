# frozen_string_literal: true

class AddIndexOnCartsOrderId < ActiveRecord::Migration[4.2]
  def change
    add_index :carts, :order_id
  end
end
