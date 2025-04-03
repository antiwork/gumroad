# frozen_string_literal: true

class IndexReviewsWithMessages < ActiveRecord::Migration[7.1]
  def up
    change_table :product_reviews, bulk: true do |t|
      t.change :id, :bigint, auto_increment: true, null: false
      t.change :purchase_id, :bigint
      t.change :link_id, :bigint
      t.boolean :has_message, null: false, as: "(IF(`message` IS NULL, FALSE, TRUE))", stored: true
      t.index [:link_id, :has_message, :created_at]
    end
  end

  def down
    change_table :product_reviews, bulk: true do |t|
      t.change :id, :int, auto_increment: true, null: false
      t.change :purchase_id, :int
      t.change :link_id, :int
      t.remove_index [:link_id, :has_message, :created_at]
      t.remove :has_message
    end
  end
end
