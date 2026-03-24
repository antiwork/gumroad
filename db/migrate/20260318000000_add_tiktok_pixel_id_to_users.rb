# frozen_string_literal: true

class AddTiktokPixelIdToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :tiktok_pixel_id, :string
  end
end
