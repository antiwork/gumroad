# frozen_string_literal: true

class AddInterruptionTimestampsToSubscriptions < ActiveRecord::Migration[4.2]
  def change
    change_table :subscriptions, bulk: true do |t|
      t.datetime :last_resubscribed_at, null: true
      t.datetime :last_deactivated_at, null: true
    end
  end
end
