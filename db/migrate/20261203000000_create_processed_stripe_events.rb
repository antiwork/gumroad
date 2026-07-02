# frozen_string_literal: true

class CreateProcessedStripeEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :processed_stripe_events do |t|
      t.string :event_id, null: false
      t.string :event_type

      t.timestamps
    end

    add_index :processed_stripe_events, :event_id, unique: true
  end
end
