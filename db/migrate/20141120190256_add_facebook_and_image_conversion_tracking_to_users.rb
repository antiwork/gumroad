# frozen_string_literal: true

class AddFacebookAndImageConversionTrackingToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :conversion_tracking_facebook_id, :string
    add_column :users, :conversion_tracking_image_url, :string
  end
end
