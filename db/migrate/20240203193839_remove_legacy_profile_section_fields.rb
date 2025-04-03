# frozen_string_literal: true

class RemoveLegacyProfileSectionFields < ActiveRecord::Migration[7.0]
  def up
    remove_columns :seller_profile_sections, :shown_products, :show_filters, :default_product_sort
  end

  def down
    change_table :seller_profile_sections, bulk: true do |t|
      t.text :shown_products
      t.boolean :show_filters
      t.string :default_product_sort
    end
  end
end
