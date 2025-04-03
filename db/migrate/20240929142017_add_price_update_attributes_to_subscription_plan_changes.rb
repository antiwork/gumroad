# frozen_string_literal: true

class AddPriceUpdateAttributesToSubscriptionPlanChanges < ActiveRecord::Migration[7.1]
  def change
    change_table :subscription_plan_changes, bulk: true do |t|
      t.date :effective_on
      t.datetime :notified_subscriber_at
    end
  end
end
