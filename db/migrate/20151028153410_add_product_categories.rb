# frozen_string_literal: true

class AddProductCategories < ActiveRecord::Migration
  def change
    create_table(:categories) do |t|
      t.string(:name, limit: 100)
      t.timestamps
    end
    add_index(:categories, :name)

    create_table(:product_categorizations) do |t|
      t.belongs_to(:category)
      t.belongs_to(:product)
      t.timestamps
    end
    add_index(:product_categorizations, :category_id)
    add_index(:product_categorizations, :product_id)
  end
end
