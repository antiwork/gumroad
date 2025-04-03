# frozen_string_literal: true

class AddMessageToProductReviews < ActiveRecord::Migration[7.0]
  def change
    add_column :product_reviews, :message, :text
  end
end
