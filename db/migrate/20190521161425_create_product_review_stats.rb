# frozen_string_literal: true

class CreateProductReviewStats < ActiveRecord::Migration
  def up
    create_table :product_review_stats do |t|
      t.references :link, index: { unique: true }
      t.integer :reviews_count, null: false, default: 0
      t.float :average_rating, null: false, default: 0.0
      t.integer :ratings_of_one_count, default: 0
      t.integer :ratings_of_two_count, default: 0
      t.integer :ratings_of_three_count, default: 0
      t.integer :ratings_of_four_count, default: 0
      t.integer :ratings_of_five_count, default: 0

      t.timestamps null: false
    end
  end

  def down
    drop_table :product_review_stats
  end
end
