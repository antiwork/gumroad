# frozen_string_literal: true

class CreateProductReviews < ActiveRecord::Migration
  def change
    create_table :product_reviews do |t|
      t.references :purchase, index: true, unique: true, foreign_key: { on_delete: :cascade }
      t.integer :rating, default: nil

      t.timestamps null: false
    end
  end
end
