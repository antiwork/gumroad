# frozen_string_literal: true

class AddHideFollowWidgetToSellerProfiles < ActiveRecord::Migration[7.0]
  def change
    add_column :seller_profiles, :hide_follow_widget, :boolean, default: false
  end
end
