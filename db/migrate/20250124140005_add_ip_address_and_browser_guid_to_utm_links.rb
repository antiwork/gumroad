# frozen_string_literal: true

class AddIpAddressAndBrowserGuidToUtmLinks < ActiveRecord::Migration[4.2]
  def change
    change_table :utm_links, bulk: true do |t|
      t.string :ip_address
      t.string :browser_guid
    end
  end
end
