# frozen_string_literal: true

class AddSellerIdAndIndexesToSubscriptionEvents < ActiveRecord::Migration[4.2]
  def change
    change_table :subscription_events, bulk: true do |t|
      t.bigint :seller_id
      t.index [:seller_id, :occurred_at]
    end
  end
end
