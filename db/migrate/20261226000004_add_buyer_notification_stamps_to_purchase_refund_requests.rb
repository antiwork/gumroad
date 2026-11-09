# frozen_string_literal: true

class AddBuyerNotificationStampsToPurchaseRefundRequests < ActiveRecord::Migration[7.1]
  def change
    change_table :purchase_refund_requests, bulk: true do |t|
      t.datetime :buyer_notified_at
      t.datetime :buyer_escalation_notified_at
      t.index %i[state buyer_escalation_notified_at created_at], name: "index_purchase_refund_requests_on_owed_buyer_retry"
    end
  end
end
