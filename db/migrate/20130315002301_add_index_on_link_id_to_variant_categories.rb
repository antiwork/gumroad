# frozen_string_literal: true

class AddIndexOnLinkIdToVariantCategories < ActiveRecord::Migration
  def change
    add_index :variant_categories, :link_id
  end
end
