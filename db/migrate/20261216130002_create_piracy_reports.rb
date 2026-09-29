# frozen_string_literal: true

class CreatePiracyReports < ActiveRecord::Migration[7.1]
  def change
    create_table :piracy_reports do |t|
      t.string :external_id, limit: 21, null: false
      t.bigint :seller_id, null: false
      t.bigint :product_id, null: false
      t.string :source, limit: 16, null: false
      t.string :ticket_url, limit: 1024
      t.string :state, limit: 32, null: false
      t.string :url, limit: 2048, null: false
      t.string :normalized_url_digest, limit: 64, null: false
      t.string :recipient_kind, limit: 16
      t.string :recipient_name
      t.string :recipient_email
      t.string :recipient_source_url, limit: 2048
      t.json :infringing_urls
      t.string :screening_verdict, limit: 16
      t.json :screening_checks
      t.datetime :screened_at
      t.text :notice_text
      t.string :notice_digest, limit: 64
      t.string :signature_statement_version, limit: 32
      t.string :signed_name
      t.datetime :signed_at
      t.string :signed_ip, limit: 45
      t.string :signed_digest, limit: 64
      t.datetime :sent_at
      t.string :sent_message_id
      t.datetime :counter_notice_received_at
      t.datetime :restore_window_opens_at
      t.datetime :restore_window_closes_at
      t.string :outcome, limit: 32
      t.datetime :closed_at

      t.timestamps

      t.index :external_id, unique: true
      t.index [:seller_id, :created_at]
      t.index [:product_id, :normalized_url_digest], unique: true
      t.index :state
    end
  end
end
