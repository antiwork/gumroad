# frozen_string_literal: true

class AddFlagsToSubscriptionPlanChanges < ActiveRecord::Migration[7.0]
  def change
    add_column :subscription_plan_changes, :flags, :bigint, default: 0, null: false
  end
end
