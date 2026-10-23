# frozen_string_literal: true

class AddSeoFieldsToSellerProfiles < ActiveRecord::Migration[8.1]
  def change
    change_table :seller_profiles, bulk: true do |t|
      t.string :seo_title
      t.text :seo_description
    end
  end
end
