# frozen_string_literal: true

class CreateProductReviewResponses < ActiveRecord::Migration[7.1]
  def change
    create_table :product_review_responses do |t|
      t.belongs_to :user, null: false
      t.belongs_to :product_review, null: false

      t.text :message

      t.timestamps
    end
  end
end
