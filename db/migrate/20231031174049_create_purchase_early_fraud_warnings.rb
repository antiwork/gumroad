# frozen_string_literal: true

class CreatePurchaseEarlyFraudWarnings < ActiveRecord::Migration[7.0]
  def change
    create_table :purchase_early_fraud_warnings do |t|
      t.bigint :purchase_id, null: false
      t.string :processor_id, null: false
      t.bigint :dispute_id
      t.bigint :refund_id
      t.string :fraud_type, null: false
      t.boolean :actionable, null: false
      t.string :charge_risk_level, null: false
      t.datetime :processor_created_at, null: false
      t.string :resolution, default: "unknown"
      t.datetime :resolved_at
      t.timestamps
    end
  end
end
