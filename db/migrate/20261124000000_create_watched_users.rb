# frozen_string_literal: true

class CreateWatchedUsers < ActiveRecord::Migration[7.1]
  def change
    create_table :watched_users do |t|
      t.references :user, null: false, index: false
      t.bigint :created_by_id
      t.bigint :revenue_threshold_cents, null: false
      t.bigint :revenue_cents, null: false, default: 0
      t.bigint :unpaid_balance_cents, null: false, default: 0
      t.datetime :last_synced_at
      t.text :notes
      t.datetime :deleted_at
      t.timestamps

      t.index [:user_id, :deleted_at]
      t.index :created_by_id
    end
  end
end
