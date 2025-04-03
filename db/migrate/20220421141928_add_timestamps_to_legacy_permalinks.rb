# frozen_string_literal: true

class AddTimestampsToLegacyPermalinks < ActiveRecord::Migration[6.1]
  def change
    change_table :legacy_permalinks, bulk: true do |t|
      t.timestamps
    end
  end
end
