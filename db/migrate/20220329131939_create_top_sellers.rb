# frozen_string_literal: true

class CreateTopSellers < ActiveRecord::Migration[6.1]
  def change
    create_table :top_sellers do |t|
      t.bigint :user_id, null: false, index: { unique: true }
      t.bigint :sales_usd, default: 0, null: false
      t.bigint :sales_count, default: 0, null: false
      t.integer :rank, null: false, index: true
      t.timestamps
    end
  end
end
