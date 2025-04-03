# frozen_string_literal: true

class RemoveAppliedAtFromSubscriptionPlanChanges < ActiveRecord::Migration[6.0]
  def up
    safety_assured { remove_column :subscription_plan_changes, :applied_at }
  end

  def down
    add_column :subscription_plan_changes, :applied_at, :datetime
  end
end
