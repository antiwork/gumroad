# frozen_string_literal: true

class RemoveIndexAndAddUniqueIndexToProductReviews < ActiveRecord::Migration
  def change
    reversible do |dir|
      dir.up do
        remove_foreign_key :product_reviews, :purchases
        remove_index :product_reviews, :purchase_id
        add_foreign_key :product_reviews, :purchases, on_delete: :cascade
        add_index :product_reviews, :purchase_id, unique: true
      end

      dir.down do
        remove_foreign_key :product_reviews, :purchases
        remove_index :product_reviews, :purchase_id
        add_foreign_key :product_reviews, :purchases, on_delete: :cascade
        add_index :product_reviews, :purchase_id
      end
    end
  end
end
