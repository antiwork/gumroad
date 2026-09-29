# frozen_string_literal: true

class CreatePiracyReportEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :piracy_report_events do |t|
      t.bigint :piracy_report_id, null: false
      t.string :event, limit: 64, null: false
      t.string :from_state, limit: 32
      t.string :to_state, limit: 32
      t.string :actor_type, limit: 16, null: false
      t.bigint :actor_id
      t.json :data
      t.datetime :created_at, null: false

      t.index [:piracy_report_id, :created_at]
    end
  end
end
