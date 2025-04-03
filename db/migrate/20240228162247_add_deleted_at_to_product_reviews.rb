# frozen_string_literal: true

class AddDeletedAtToProductReviews < ActiveRecord::Migration[7.1]
  def change
    add_column :product_reviews, :deleted_at, :datetime
  end
end
