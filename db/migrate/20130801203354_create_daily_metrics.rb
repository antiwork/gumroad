# frozen_string_literal: true

class CreateDailyMetrics < ActiveRecord::Migration
  def change
    create_table :daily_metrics do |t|
      t.string :event_name
      t.date :events_date
      t.integer :event_count
      t.integer :user_count

      t.timestamps
    end

    add_index :daily_metrics, [:event_name, :events_date], unique: true
  end
end
