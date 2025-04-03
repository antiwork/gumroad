# frozen_string_literal: true

class CreateProductReviewVideos < ActiveRecord::Migration[7.1]
  def change
    create_table :product_review_videos do |t|
      t.references :product_review, null: false, foreign_key: false
      t.string :approval_status, default: "pending_review"
      t.datetime :deleted_at, index: true

      t.timestamps
    end
  end
end
