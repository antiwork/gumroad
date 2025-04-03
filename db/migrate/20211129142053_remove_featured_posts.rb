# frozen_string_literal: true

class RemoveFeaturedPosts < ActiveRecord::Migration[6.1]
  def up
    drop_table :featured_posts
  end

  def down
    create_table :featured_posts do |t|
      t.integer :post_id, null: false, index: true
      t.string :category, null: false, index: { unique: true }, limit: 191

      t.timestamps null: false
    end
  end
end
