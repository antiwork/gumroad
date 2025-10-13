# frozen_string_literal: true

class CreateCreatorAnalyticsChurnCaches < ActiveRecord::Migration[7.1]
  def change
    create_table :creator_analytics_churn_caches do |t|
      t.references :user, null: false, index: true, foreign_key: true
      t.date :date, null: false

      t.decimal :customer_churn_rate, precision: 5, scale: 2, default: 0.0
      t.integer :churned_subscribers, default: 0, null: false
      t.bigint :churned_mrr_cents, default: 0, null: false

      t.timestamps

      t.index [:user_id, :date], unique: true
      t.index :date
    end
  end
end

