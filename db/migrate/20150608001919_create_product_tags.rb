# frozen_string_literal: true

class CreateProductTags < ActiveRecord::Migration
  def change
    create_table :product_tags, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_unicode_ci" do |t|
      t.references :link
      t.string :tag
      t.string :tag_value

      t.timestamps
      t.datetime :deleted_at
    end

    add_index :product_tags, [:link_id, :tag], unique: true
  end
end
