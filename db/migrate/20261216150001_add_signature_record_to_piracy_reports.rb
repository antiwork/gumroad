# frozen_string_literal: true

class AddSignatureRecordToPiracyReports < ActiveRecord::Migration[7.1]
  def change
    change_table :piracy_reports, bulk: true do |t|
      t.string :signature_statement_version
      t.string :signed_ip
    end
  end
end
