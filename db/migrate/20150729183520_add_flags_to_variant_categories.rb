# frozen_string_literal: true

class AddFlagsToVariantCategories < ActiveRecord::Migration
  def change
    add_column :variant_categories, :flags, :integer, default: 0, null: false
  end
end
