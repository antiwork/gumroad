# frozen_string_literal: true

class AddInterruptionTimestampsToSubscriptions < ActiveRecord::Migration[6.1]
  def change
    change_table :subscriptions, bulk: true do |t|
      t.datetime :last_resubscribed_at, null: true
      t.datetime :last_deactivated_at, null: true
    end
  end
end
