# frozen_string_literal: true

class AddNewThirdPartyAnalyticFields < ActiveRecord::Migration[4.2]
  def change
    change_table :third_party_analytics, bulk: true do |t|
      t.string :name
      t.string :location, default: "receipt"
    end
  end
end
