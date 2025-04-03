# frozen_string_literal: true

class AddEmailBrowserGuidAndIpAddressToCarts < ActiveRecord::Migration[7.1]
  def change
    change_table :carts, bulk: true do |t|
      t.string :email, index: true
      t.string :browser_guid, index: true
      t.string :ip_address
    end
  end
end
