# frozen_string_literal: true

class AddDeliveryToPiracyReports < ActiveRecord::Migration[7.1]
  def change
    change_table :piracy_reports, bulk: true do |t|
      # What went out, frozen at send, so a later edit cannot rewrite the record of the dispatch.
      t.string :final_notice_digest, limit: 64
      t.datetime :sent_at
      t.string :sent_message_id
      t.string :sent_to_email, limit: 254
      t.string :delivery_status, limit: 32
      # Counter-notices come back to support@, so each report needs its own Reply-To to be routed.
      t.string :reply_token, limit: 32
      t.datetime :counter_notice_received_at
      t.text :counter_notice_body
      t.datetime :counter_notice_forwarded_at
      t.datetime :resolved_at
      t.string :resolution, limit: 32
    end

    add_index :piracy_reports, :reply_token, unique: true
  end
end
