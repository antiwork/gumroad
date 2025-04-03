# frozen_string_literal: true

class CreatePrices < ActiveRecord::Migration
  def change
    create_table :prices, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_unicode_ci" do |t|
      t.references :link
      t.integer :price_cents, default: 0, null: false
      t.string :currency, default: "usd"
      t.string :recurrence

      t.timestamps
      t.datetime :deleted_at
      t.integer :flags, default: 0, null: false
    end

    add_index :prices, :link_id
  end
end
