# frozen_string_literal: true

class AddSignatureToPiracyReports < ActiveRecord::Migration[7.1]
  def change
    change_table :piracy_reports, bulk: true do |t|
      t.datetime :signed_at
      t.string :signed_by_name
    end
  end
end
