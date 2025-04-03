# frozen_string_literal: true

class UpdateDailyMetricsIndex < ActiveRecord::Migration
  def up
    add_index :daily_metrics, [:event_name, :events_date, :source_type], name: "index_daily_metrics_on_event_name_events_date_and_source_type", unique: true
  end

  def down
    remove_index :daily_metrics, name: "index_daily_metrics_on_event_name_events_date_and_source_type"
  end
end
