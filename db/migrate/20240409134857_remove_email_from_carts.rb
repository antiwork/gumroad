# frozen_string_literal: true

class RemoveEmailFromCarts < ActiveRecord::Migration[7.1]
  def change
    remove_column :carts, :email, :string
  end
end
