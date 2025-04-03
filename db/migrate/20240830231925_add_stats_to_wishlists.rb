# frozen_string_literal: true

class AddStatsToWishlists < ActiveRecord::Migration[7.1]
  def change
    change_table :wishlists, bulk: true do |t|
      t.integer :flags, default: 0, null: false
      t.boolean :recommendable, default: false, null: false
      t.integer :follower_count, default: 0, null: false
      t.integer :recent_follower_count, default: 0, null: false
      t.index [:recommendable, :recent_follower_count]
    end
  end
end
