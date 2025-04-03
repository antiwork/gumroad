# frozen_string_literal: true

class DropSubscriptionInterruptionTimestamps < ActiveRecord::Migration[7.0]
  def up
    change_table :subscriptions, bulk: true do |t|
      t.remove :last_resubscribed_at
      t.remove :last_deactivated_at
    end
  end

  def down
    change_table :subscriptions, bulk: true do |t|
      t.datetime :last_resubscribed_at
      t.datetime :last_deactivated_at
    end
  end
end
