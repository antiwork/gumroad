# frozen_string_literal: true

class AddBorderRadiusAndButtonHoverToSellerProfiles < ActiveRecord::Migration[8.1]
  def change
    change_table :seller_profiles, bulk: true do |t|
      t.string :border_radius
      t.string :button_hover
    end
  end
end
