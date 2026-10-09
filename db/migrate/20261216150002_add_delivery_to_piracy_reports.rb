# frozen_string_literal: true

class AddDeliveryToPiracyReports < ActiveRecord::Migration[7.1]
  def change
    change_table :piracy_reports, bulk: true do |t|
      t.string :reply_token
      t.datetime :sent_at
      t.string :sent_message_id
      t.string :sent_to_email
      t.string :last_contact_email
      t.datetime :delivered_at
      t.datetime :delivery_failed_at
      t.index :reply_token, unique: true
    end
  end
end
