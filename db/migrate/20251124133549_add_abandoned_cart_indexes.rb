# frozen_string_literal: true

class AddAbandonedCartIndexes < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    add_index :carts, [:deleted_at, :updated_at]
    add_index :cart_products, [:deleted_at, :cart_id]
  end
end
