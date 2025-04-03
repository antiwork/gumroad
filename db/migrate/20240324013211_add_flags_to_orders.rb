# frozen_string_literal: true

class AddFlagsToOrders < ActiveRecord::Migration[7.1]
  def change
    add_column :orders, :flags, :bigint, default: 0, null: false
  end
end
