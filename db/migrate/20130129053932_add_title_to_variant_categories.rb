# frozen_string_literal: true

class AddTitleToVariantCategories < ActiveRecord::Migration[4.2]
  def change
    add_column :variant_categories, :title, :string
  end
end
