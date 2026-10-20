# frozen_string_literal: true

class CreateFeatureAnnouncementDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :feature_announcement_deliveries do |t|
      t.string :campaign, limit: 64, null: false
      t.bigint :user_id, null: false
      t.string :email, null: false
      t.string :state, limit: 16, null: false
      t.string :reason, limit: 64
      t.timestamps

      t.index [:campaign, :user_id], unique: true
      t.index [:campaign, :email], unique: true
      t.index [:campaign, :state]
    end
  end
end
