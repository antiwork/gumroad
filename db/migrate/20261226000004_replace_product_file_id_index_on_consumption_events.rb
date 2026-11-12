# frozen_string_literal: true

class ReplaceProductFileIdIndexOnConsumptionEvents < ActiveRecord::Migration[8.1]
  NEW_INDEX = "index_consumption_events_on_file_type_created_purchase"
  NEW_COLUMNS = [:product_file_id, :event_type, :created_at, :purchase_id].freeze
  OLD_INDEX = "index_consumption_events_on_product_file_id"

  # Built by hand in production with pt-osc: at this table's size the copy cannot ride a deploy
  # (gumroad-private#4550), so there the deploy only records this version. The new index leads with
  # product_file_id, so it serves every query the old one did.
  def up
    return if Rails.env.production?

    change_table :consumption_events, bulk: true do |t|
      t.index NEW_COLUMNS, name: NEW_INDEX
      t.remove_index name: OLD_INDEX
    end
  end

  def down
    return if Rails.env.production?

    change_table :consumption_events, bulk: true do |t|
      t.index :product_file_id, name: OLD_INDEX
      t.remove_index name: NEW_INDEX
    end
  end
end
