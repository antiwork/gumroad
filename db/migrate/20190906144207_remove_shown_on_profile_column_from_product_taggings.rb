# frozen_string_literal: true

class RemoveShownOnProfileColumnFromProductTaggings < ActiveRecord::Migration
  def up
    remove_column :product_taggings, :shown_on_profile
  end

  def down
    add_column :product_taggings, :shown_on_profile, :boolean
    change_column_default :product_taggings, :shown_on_profile, true
  end
end
