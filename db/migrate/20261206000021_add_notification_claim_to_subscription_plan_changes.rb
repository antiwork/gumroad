# frozen_string_literal: true

class AddNotificationClaimToSubscriptionPlanChanges < ActiveRecord::Migration[7.1]
  def change
    change_table :subscription_plan_changes, bulk: true do |t|
      t.string :notification_claim_id, limit: 36
      t.datetime :notification_claimed_at, precision: 6
    end
  end
end
