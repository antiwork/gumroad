# frozen_string_literal: true

class CreateConsumptionEvents < ActiveRecord::Migration
  def change
    create_table :consumption_events, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_unicode_ci" do |t|
      t.integer :product_file_id
      t.integer :url_redirect_id
      t.integer :purchase_id
      t.string :event_type
      t.string :platform

      t.integer :flags, default: 0, null: false
      t.text :json_data
      t.timestamps
    end

    add_index :consumption_events, :product_file_id
    add_index :consumption_events, :purchase_id
  end
end
