# frozen_string_literal: true

class AddMessageToProductReviews < ActiveRecord::Migration[4.2]
  def change
    add_column :product_reviews, :message, :text
  end
end
