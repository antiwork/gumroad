# frozen_string_literal: true

class AddIndexOnCartsUpdatedAt < ActiveRecord::Migration[4.2]
  def change
    add_index :carts, :updated_at
  end
end
