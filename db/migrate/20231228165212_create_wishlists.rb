# frozen_string_literal: true

class CreateWishlists < ActiveRecord::Migration[7.0]
  def change
    create_table :wishlists do |t|
      t.references :user, null: false
      t.string :name, null: false
      t.datetime :deleted_at

      t.timestamps
    end
  end
end
