# frozen_string_literal: true

class CreateCommunities < ActiveRecord::Migration[7.1]
  def change
    create_table :communities do |t|
      t.references :resource, polymorphic: true, null: false
      t.references :seller, null: false
      t.datetime :deleted_at, index: true

      t.timestamps

      t.index [:resource_type, :resource_id, :seller_id, :deleted_at], unique: true
    end
  end
end
