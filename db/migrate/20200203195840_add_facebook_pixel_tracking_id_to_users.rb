# frozen_string_literal: true

class AddFacebookPixelTrackingIdToUsers < ActiveRecord::Migration
  def up
    add_column :users, :facebook_pixel_id, :string
  end

  def down
    remove_column :users, :facebook_pixel_id
  end
end
