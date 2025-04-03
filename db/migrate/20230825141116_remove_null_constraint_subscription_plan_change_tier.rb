# frozen_string_literal: true

class RemoveNullConstraintSubscriptionPlanChangeTier < ActiveRecord::Migration[7.0]
  def change
    change_column_null :subscription_plan_changes, :base_variant_id, true
  end
end
