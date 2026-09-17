# frozen_string_literal: true

class CreateMarketingMetricsSnapshots < ActiveRecord::Migration[7.2]
  def change
    create_table :marketing_metrics_snapshots do |t|
      t.datetime :window_start, null: false
      t.datetime :window_end, null: false
      t.string :cohort, null: false
      t.json :metrics, null: false
      t.timestamps
      t.index [:window_start, :window_end, :cohort], unique: true, name: "index_marketing_metrics_snapshots_on_window_and_cohort"
    end
  end
end
