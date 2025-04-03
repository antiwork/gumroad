# frozen_string_literal: true

class CreateSubscriptionPlanChanges < ActiveRecord::Migration[5.2]
  def change
    create_table :subscription_plan_changes do |t|
      t.references :subscription, null: false, index: true
      t.references :base_variant, null: false, index: true
      t.string :recurrence, null: false
      t.integer :perceived_price_cents, null: false
      t.datetime :applied_at
      t.datetime :deleted_at

      t.timestamps
    end
  end
end
