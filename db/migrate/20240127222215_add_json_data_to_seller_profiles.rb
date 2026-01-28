# frozen_string_literal: true

class AddJsonDataToSellerProfiles < ActiveRecord::Migration[4.2]
  def change
    add_column :seller_profiles, :json_data, :json
  end
end
