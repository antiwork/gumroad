# frozen_string_literal: true

class AddCompositeIndexesToPurchases < ActiveRecord::Migration[7.1]
  def change
    add_index :purchases, [:link_id, :purchaser_id, :refunded_at, :disputed_at], name: 'index_purchases_on_link_purchaser_refund_dispute'
    add_index :purchases, [:link_id, :email, :refunded_at, :disputed_at], name: 'index_purchases_on_link_email_refund_dispute'
  end
end
