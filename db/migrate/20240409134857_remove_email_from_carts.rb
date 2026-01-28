# frozen_string_literal: true

class RemoveEmailFromCarts < ActiveRecord::Migration[4.2]
  def change
    remove_column :carts, :email, :string
  end
end
