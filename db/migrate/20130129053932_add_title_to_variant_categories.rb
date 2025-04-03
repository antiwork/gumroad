# frozen_string_literal: true

class AddTitleToVariantCategories < ActiveRecord::Migration
  def change
    add_column :variant_categories, :title, :string
  end
end
