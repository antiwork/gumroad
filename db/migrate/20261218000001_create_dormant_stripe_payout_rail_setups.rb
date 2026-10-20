# frozen_string_literal: true

class CreateDormantStripePayoutRailSetups < ActiveRecord::Migration[8.1]
  def change
    create_table :stripe_payout_rail_setups do |t|
      t.bigint :user_id, null: false
      t.integer :bank_account_id, null: false
      t.bigint :merchant_account_id
      t.string :state, null: false, default: "pending"
      t.string :attempt_token
      t.datetime :attempt_started_at
      t.integer :attempt_count, null: false, default: 0
      t.datetime :prepared_at
      t.datetime :failed_at
      t.string :failure_code
      t.datetime :activated_at
      t.bigint :activated_by_id
      t.string :consent_reference
      t.timestamps

      t.index [:user_id, :state]
      t.index :merchant_account_id
    end
  end
end
