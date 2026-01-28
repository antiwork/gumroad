# frozen_string_literal: true

class AddSellerIdAndIndexesToSubscriptions < ActiveRecord::Migration[4.2]
  def change
    change_table :subscriptions, bulk: true do |t|
      t.bigint :seller_id
      t.index [:seller_id, :created_at]
    end
  end
end
