# frozen_string_literal: true

class AddDeletedAtToWishlistProducts < ActiveRecord::Migration[7.0]
  def change
    add_column :wishlist_products, :deleted_at, :datetime
  end
end
