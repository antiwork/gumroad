# frozen_string_literal: true

class AddDisputesSellerId < ActiveRecord::Migration[7.0]
  def change
    change_table :disputes, bulk: true do |t|
      t.bigint :seller_id
      t.datetime :event_created_at
      t.index [:seller_id, :event_created_at]
      t.index [:seller_id, :won_at]
      t.index [:seller_id, :lost_at]
    end
  end
end
