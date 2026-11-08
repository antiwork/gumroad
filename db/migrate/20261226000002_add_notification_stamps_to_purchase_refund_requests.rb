# frozen_string_literal: true

class AddNotificationStampsToPurchaseRefundRequests < ActiveRecord::Migration[7.1]
  def change
    # Small, new table — safe DDL. Stamps make notification delivery durable
    # and exactly-once-able: nil means "owed", a timestamp means "sent".
    change_table :purchase_refund_requests, bulk: true do |t|
      t.datetime :seller_notified_at
      t.datetime :support_notified_at
    end
  end
end
