# frozen_string_literal: true

class CreateLargeSellers < ActiveRecord::Migration
  def change
    create_table :large_sellers do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.integer :sales_count, null: false, default: 0
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false, index: true
    end
  end
end
