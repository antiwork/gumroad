# frozen_string_literal: true

class AddIndexOnLinkIdToVariantCategories < ActiveRecord::Migration[4.2]
  def change
    add_index :variant_categories, :link_id
  end
end
