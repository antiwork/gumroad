# frozen_string_literal: true

class RemoveUnusedUsersColumns202011 < ActiveRecord::Migration[6.0]
  def up
    change_table :users do |t|
      t.remove :background_video_url
      t.remove :number_of_views
      t.remove :absorbed_to_user_id
      t.remove :beta
      t.remove :soundcloud_username
      t.remove :soundcloud_token
      t.remove :platform_cut
      t.remove :ban_flag
      t.remove :ban_queued
      t.remove :autoban_flag
      t.remove :autobanned_at
      t.remove :digest_sent_at
      t.remove :external_css_url
      t.remove :is_developer
      t.remove :conversion_tracking_facebook_id
      t.remove :conversion_tracking_image_url
    end
  end

  def down
    change_table :users do |t|
      t.string :background_video_url, limit: 255
      t.integer :number_of_views
      t.integer :absorbed_to_user_id
      t.boolean :beta
      t.string :soundcloud_username, limit: 255
      t.string :soundcloud_token, limit: 255
      t.float :platform_cut
      t.boolean :ban_flag
      t.boolean :ban_queued
      t.boolean :autoban_flag
      t.datetime :autobanned_at
      t.datetime :digest_sent_at
      t.string :external_css_url, limit: 255
      t.boolean :is_developer, default: false
      t.string :conversion_tracking_facebook_id, limit: 255
      t.string :conversion_tracking_image_url, limit: 255
    end
  end
end
