# frozen_string_literal: true

class AddOutcomeNotifiedAtToPiracyReports < ActiveRecord::Migration[7.1]
  def change
    change_table :piracy_reports, bulk: true do |t|
      t.datetime :outcome_notified_at
      t.index %i[counter_notice_received_on seller_id]
    end
  end
end
