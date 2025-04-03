# frozen_string_literal: true

class AddDeletedAtAndDisabledAtToUtmLinks < ActiveRecord::Migration[7.1]
  def change
    change_table :utm_links, bulk: true do |t|
      t.datetime :deleted_at, precision: nil, index: true
      t.datetime :disabled_at, precision: nil
    end
  end
end
