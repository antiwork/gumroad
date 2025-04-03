# frozen_string_literal: true

class AddIndexOnCartsUpdatedAt < ActiveRecord::Migration[7.1]
  def change
    add_index :carts, :updated_at
  end
end
