# frozen_string_literal: true

class AddSeoFieldsToSellerProfiles < ActiveRecord::Migration[8.1]
  # Renumbered from 20261219000004, which the pages SEO migration now uses. A
  # preview database that ran the old number already has the columns.
  def up
    return if column_exists?(:seller_profiles, :seo_title)

    change_table :seller_profiles, bulk: true do |t|
      t.string :seo_title
      t.text :seo_description
    end
  end

  def down
    change_table :seller_profiles, bulk: true do |t|
      t.remove :seo_title, :seo_description
    end
  end
end
