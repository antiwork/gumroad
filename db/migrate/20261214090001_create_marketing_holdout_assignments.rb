# frozen_string_literal: true

class CreateMarketingHoldoutAssignments < ActiveRecord::Migration[7.1]
  def change
    create_table :marketing_holdout_assignments, if_not_exists: true do |t|
      t.references :user, null: false, index: { unique: true }
      t.string :prior_sales_bucket, null: false
      t.boolean :marketing_holdout, null: false
      t.datetime :marketing_holdout_assigned_at, null: false
    end
  end
end
