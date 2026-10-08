# frozen_string_literal: true

class AddOutcomeToPiracyReports < ActiveRecord::Migration[7.1]
  def change
    change_table :piracy_reports, bulk: true do |t|
      t.text :counter_notice_body
      t.date :counter_notice_received_on
      t.datetime :counter_notice_forwarded_at
      t.string :outcome
      t.text :outcome_reason
      t.datetime :resolved_at
      t.datetime :outcome_notified_at
      t.index %i[counter_notice_received_on seller_id]
    end
  end
end
