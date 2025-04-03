# frozen_string_literal: true

class AddSellerIdAndIndexesToSubscriptions < ActiveRecord::Migration[7.0]
  def change
    change_table :subscriptions, bulk: true do |t|
      t.bigint :seller_id
      t.index [:seller_id, :created_at]
    end
  end
end
