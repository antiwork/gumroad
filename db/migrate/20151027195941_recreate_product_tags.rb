# frozen_string_literal: true

class RecreateProductTags < ActiveRecord::Migration
  def change
    create_table(:tags) do |t|
      t.string(:name, limit: 100)
      t.timestamps
    end
    add_index(:tags, :name)

    create_table(:product_taggings) do |t|
      t.belongs_to(:tag)
      t.belongs_to(:product)
      t.timestamps
    end
    add_index(:product_taggings, :tag_id)
    add_index(:product_taggings, :product_id)
  end
end
