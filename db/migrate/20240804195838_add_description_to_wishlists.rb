# frozen_string_literal: true

class AddDescriptionToWishlists < ActiveRecord::Migration[4.2]
  def change
    add_column :wishlists, :description, :text
  end
end
