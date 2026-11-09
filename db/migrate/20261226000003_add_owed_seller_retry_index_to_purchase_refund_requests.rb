# frozen_string_literal: true

class AddOwedSellerRetryIndexToPurchaseRefundRequests < ActiveRecord::Migration[7.1]
  def change
    add_index :purchase_refund_requests, %i[state seller_notified_at created_at], name: "index_purchase_refund_requests_on_owed_seller_retry"
  end
end
