# frozen_string_literal: true

class CreatePurchases < ActiveRecord::Migration
  def change
    create_table :purchases do |t|
      t.integer :user_id
      t.string :unique_permalink
      t.float :price
      t.date :created_at

      t.timestamps
    end
  end
end
