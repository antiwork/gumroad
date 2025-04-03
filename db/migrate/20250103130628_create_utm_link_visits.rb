# frozen_string_literal: true

class CreateUtmLinkVisits < ActiveRecord::Migration[7.1]
  def change
    create_table :utm_link_visits do |t|
      t.references :utm_link, null: false
      t.references :user
      t.string :referrer
      t.string :ip_address, null: false
      t.string :user_agent
      t.string :browser_guid, null: false, index: true
      t.string :country_code, null: false
      t.timestamps

      t.index [:created_at]
    end
  end
end
