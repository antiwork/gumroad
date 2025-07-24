# frozen_string_literal: true

class CreatePurchases < ActiveRecord::Migration[7.1]
  def change
    create_table :purchases do |t|
      t.integer :user_id
      t.string :unique_permalink
      t.float :price

      t.timestamps
    end
  end
end
