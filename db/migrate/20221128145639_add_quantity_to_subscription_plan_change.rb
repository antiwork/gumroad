# frozen_string_literal: true

class AddQuantityToSubscriptionPlanChange < ActiveRecord::Migration[4.2]
  def change
    change_table :subscription_plan_changes, bulk: true do |t|
      t.integer "quantity", default: 1, null: false
    end
  end
end
