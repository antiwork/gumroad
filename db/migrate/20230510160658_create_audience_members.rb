# frozen_string_literal: true

class CreateAudienceMembers < ActiveRecord::Migration[7.0]
  def change
    create_table :audience_members do |t|
      t.bigint :seller_id, null: false
      t.string :email, null: false
      t.json :details
      t.timestamps
      t.index [:seller_id, :email], unique: true

      # derived columns and their indexes, used for performance reasons
      t.boolean :customer, default: false, null: false
      t.boolean :follower, default: false, null: false
      t.boolean :affiliate, default: false, null: false
      t.integer :min_paid_cents
      t.integer :max_paid_cents
      t.datetime :min_created_at, precision: nil
      t.datetime :max_created_at, precision: nil
      t.datetime :min_purchase_created_at, precision: nil
      t.datetime :max_purchase_created_at, precision: nil
      t.datetime :follower_created_at, precision: nil
      t.datetime :min_affiliate_created_at, precision: nil
      t.datetime :max_affiliate_created_at, precision: nil

      t.index "seller_id, (cast(json_extract(`details`, '$.purchases[*].product_id') as unsigned array))", name: "idx_audience_on_seller_and_purchases_products_ids"
      t.index "seller_id, (cast(json_extract(`details`, '$.purchases[*].variant_id') as unsigned array))", name: "idx_audience_on_seller_and_purchases_variants_ids"
      t.index "seller_id, (cast(json_extract(`details`, '$.purchases[*].country') as char(100) array))", name: "idx_audience_on_seller_and_purchases_countries"
      t.index [:seller_id, :customer, :follower, :affiliate], name: "idx_audience_on_seller_and_types"
      t.index [:seller_id, :min_paid_cents, :max_paid_cents], name: "idx_audience_on_seller_and_minmax_paid_cents"
      t.index [:seller_id, :min_created_at, :max_created_at], name: "idx_audience_on_seller_and_minmax_created_at"
      t.index [:seller_id, :min_purchase_created_at, :max_purchase_created_at], name: "idx_audience_on_seller_and_minmax_purchase_created_at"
      t.index [:seller_id, :follower_created_at], name: "idx_audience_on_seller_and_follower_created_at"
      t.index [:seller_id, :min_affiliate_created_at, :max_affiliate_created_at], name: "idx_audience_on_seller_and_minmax_affiliate_created_at"
    end
  end
end
