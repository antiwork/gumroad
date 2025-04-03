# frozen_string_literal: true

class CreateUtmLinks < ActiveRecord::Migration[7.1]
  def change
    create_table :utm_links do |t|
      t.references :seller, null: false
      t.string :title, null: false
      t.string :target_resource_type, null: false
      t.string :target_resource_id
      t.string :permalink, null: false, index: { unique: true }
      t.string :utm_campaign, null: false, index: true
      t.string :utm_medium, null: false
      t.string :utm_source
      t.string :utm_term
      t.string :utm_content
      t.datetime :first_click_at
      t.datetime :last_click_at
      t.integer :total_clicks, default: 0, null: false
      t.integer :unique_clicks, default: 0, null: false
      t.timestamps
      t.index [:target_resource_type, :target_resource_id]
    end
  end
end
