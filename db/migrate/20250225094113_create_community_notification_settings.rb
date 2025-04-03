# frozen_string_literal: true

class CreateCommunityNotificationSettings < ActiveRecord::Migration[7.1]
  def change
    create_table :community_notification_settings do |t|
      t.references :user, null: false
      t.references :seller, null: false
      t.string :recap_frequency, index: true

      t.timestamps

      t.index [:user_id, :seller_id], unique: true
    end
  end
end
