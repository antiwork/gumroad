# frozen_string_literal: true

class CreateSubscriptionEvents < ActiveRecord::Migration[7.0]
  def change
    create_table :subscription_events do |t|
      t.references :subscription, null: false
      t.integer :event_type, null: false
      t.datetime :occurred_at, null: false

      t.timestamps
    end
  end
end
