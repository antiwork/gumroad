# frozen_string_literal: true

class CreateMediaLocation < ActiveRecord::Migration[6.1]
  def change
    create_table :media_locations do |t|
      t.integer :product_file_id, null: false
      t.integer :url_redirect_id, null: false
      t.integer :purchase_id, null: false
      t.integer :link_id, null: false
      t.datetime :consumed_at
      t.string :platform
      t.integer :location, null: false
      t.integer :content_length, null: false
      t.string :unit, null: false

      t.timestamps
    end

    add_index :media_locations, :product_file_id
    add_index :media_locations, :purchase_id
  end
end
