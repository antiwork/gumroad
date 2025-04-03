# frozen_string_literal: true

class RemoveIndexFromDailyMetrics < ActiveRecord::Migration
  def up
    remove_index :daily_metrics, name: "index_daily_metrics_on_event_name_and_events_date"
  end
end
