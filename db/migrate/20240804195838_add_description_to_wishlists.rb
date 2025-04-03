# frozen_string_literal: true

class AddDescriptionToWishlists < ActiveRecord::Migration[7.1]
  def change
    add_column :wishlists, :description, :text
  end
end
