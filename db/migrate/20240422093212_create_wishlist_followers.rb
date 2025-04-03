# frozen_string_literal: true

class CreateWishlistFollowers < ActiveRecord::Migration[7.1]
  def change
    create_table :wishlist_followers do |t|
      t.belongs_to :wishlist, null: false
      t.belongs_to :follower_user, null: false
      t.datetime :deleted_at

      t.timestamps
    end
  end
end
