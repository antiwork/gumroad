# frozen_string_literal: true

class CreateScheduledPayouts < ActiveRecord::Migration[7.1]
  def change
    create_table :scheduled_payouts do |t|
      t.references :user, null: false, index: true
      t.string :action, null: false
      t.integer :delay_days, null: false, default: 21
      t.datetime :scheduled_at, null: false
      t.string :status, null: false, default: "pending"
      t.bigint :created_by_id
      t.datetime :executed_at
      t.bigint :payout_amount_cents
      t.timestamps

      t.index [:status, :scheduled_at]
      t.index :created_by_id
    end
  end
end
