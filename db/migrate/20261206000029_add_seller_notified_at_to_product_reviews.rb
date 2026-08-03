# frozen_string_literal: true

class AddSellerNotifiedAtToProductReviews < ActiveRecord::Migration[7.1]
  def change
    add_column :product_reviews, :seller_notified_at, :datetime
  end
end
