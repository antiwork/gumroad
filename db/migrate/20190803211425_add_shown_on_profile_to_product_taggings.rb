# frozen_string_literal: true

class AddShownOnProfileToProductTaggings < ActiveRecord::Migration
  def up
    add_column :product_taggings, :shown_on_profile, :boolean
    change_column_default :product_taggings, :shown_on_profile, true
  end

  def down
    remove_column :product_taggings, :shown_on_profile
  end
end
