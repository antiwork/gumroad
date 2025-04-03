# frozen_string_literal: true

class CreateFeaturedPosts < ActiveRecord::Migration[6.0]
  def change
    create_table :featured_posts do |t|
      t.integer :post_id, null: false
      t.string :category, null: false, index: { unique: true }

      t.timestamps null: false
    end

    # `on_delete: :restrict, on_update: :restrict` are default options
    add_foreign_key :featured_posts, :installments, column: :post_id
  end
end
