# frozen_string_literal: true

class CreateFailedRefundExceptions < ActiveRecord::Migration[7.1]
  def change
    create_table :failed_refund_exceptions do |t|
      t.bigint :refund_id, null: false
      t.string :owner, null: false
      t.string :notification_room, null: false
      t.string :state, null: false, default: "pending"
      t.datetime :due_at, null: false
      t.boolean :balance_reversed, null: false, default: false
      t.integer :notification_failures, null: false, default: 0
      t.datetime :notification_sent_at
      t.datetime :resolved_at
      t.text :resolution

      t.timestamps
      t.index :refund_id, unique: true
      t.index [:state, :notification_sent_at],
              name: "idx_failed_refund_exceptions_pending_notification"
      t.index [:state, :due_at],
              name: "idx_failed_refund_exceptions_on_state_due_at"
    end
  end
end
