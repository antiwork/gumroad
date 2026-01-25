# frozen_string_literal: true
#
class AddIndexesToAudienceMembers < ActiveRecord::Migration[7.1]
  def change
    change_table :audience_members, bulk: true do |t|
      t.index [:seller_id, :customer, :min_created_at],
              name: "idx_audience_customer_created_at"

      t.index [:seller_id, :follower, :min_created_at],
              name: "idx_audience_follower_created_at_flag"

      t.index [:seller_id, :affiliate, :min_created_at],
              name: "idx_audience_affiliate_created_at"
    end
  end
end
