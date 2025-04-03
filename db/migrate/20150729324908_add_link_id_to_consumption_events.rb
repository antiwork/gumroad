# frozen_string_literal: true

class AddLinkIdToConsumptionEvents < ActiveRecord::Migration
  def change
    add_column :consumption_events, :link_id, :integer
    add_index :consumption_events, :link_id
  end
end
