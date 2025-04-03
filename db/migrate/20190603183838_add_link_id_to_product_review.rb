# frozen_string_literal: true

class AddLinkIdToProductReview < ActiveRecord::Migration
  def up
    add_column :product_reviews, :link_id, :integer
  end

  def down
    remove_column :product_reviews, :link_id
  end
end
