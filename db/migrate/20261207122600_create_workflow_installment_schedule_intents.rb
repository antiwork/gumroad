# frozen_string_literal: true

# Main already records a future schema version, so this timestamp must sort after it.
class CreateWorkflowInstallmentScheduleIntents < ActiveRecord::Migration[7.1]
  def change
    create_table :workflow_installment_schedule_intents do |t|
      t.string :token, null: false
      t.integer :installment_id, null: false
      t.integer :rule_version, null: false
      t.integer :old_delayed_delivery_time
      t.datetime :cutoff_reference_time, null: false
      t.datetime :expected_published_at
      t.string :dispatch_token
      t.datetime :dispatch_expires_at
      t.string :fanout_token
      t.datetime :fanout_expires_at
      t.datetime :processed_at
      t.timestamps

      t.index :token, unique: true
      t.index :installment_id
      t.index [:processed_at, :dispatch_expires_at, :fanout_expires_at], name: "index_workflow_intent_on_pending_dispatch"
    end
  end
end
