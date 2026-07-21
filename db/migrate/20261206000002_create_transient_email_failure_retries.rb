# frozen_string_literal: true

class CreateTransientEmailFailureRetries < ActiveRecord::Migration[7.1]
  def change
    create_table :transient_email_failure_retries do |t|
      t.string :email, null: false
      t.string :mail_kind, null: false
      t.integer :attempts, null: false, default: 0
      t.boolean :retry_in_flight, null: false, default: false
      t.text :last_reason

      t.timestamps
      t.index [:email, :mail_kind], unique: true
    end
  end
end
