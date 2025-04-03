# frozen_string_literal: true

class AddParentIdToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :parent_id, :integer
    add_column :purchases, :flags, :integer, default: 0, null: false
  end
end
