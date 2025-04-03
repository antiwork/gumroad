# frozen_string_literal: true

class CreateSalesStats < ActiveRecord::Migration[7.0]
  def set_up_common_columns(t)
    t.bigint :sales_cents, default: 0, null: false
    t.bigint :refunds_cents, default: 0, null: false
    t.bigint :disputes_cents, default: 0, null: false
    t.bigint :dispute_reversals_cents, default: 0, null: false
    t.bigint :net_revenue_cents, as: "sales_cents - refunds_cents - disputes_cents + dispute_reversals_cents", stored: true, null: false

    t.bigint :fees_cents, default: 0, null: false
    t.bigint :fees_refunds_cents, default: 0, null: false
    t.bigint :fees_disputes_cents, default: 0, null: false
    t.bigint :fees_dispute_reversals_cents, default: 0, null: false
    t.bigint :net_fees_cents, as: "fees_cents - fees_refunds_cents - fees_disputes_cents + fees_dispute_reversals_cents", stored: true, null: false

    t.bigint :affiliate_sales_cents, default: 0, null: false
    t.bigint :affiliate_refunds_cents, default: 0, null: false
    t.bigint :affiliate_disputes_cents, default: 0, null: false
    t.bigint :affiliate_dispute_reversals_cents, default: 0, null: false
    t.bigint :net_affiliate_revenue_cents, as: "affiliate_sales_cents - affiliate_refunds_cents - affiliate_disputes_cents + affiliate_dispute_reversals_cents", stored: true, null: false

    t.bigint :adjusted_net_revenue_cents, as: "net_revenue_cents - net_fees_cents - net_affiliate_revenue_cents", stored: true, null: false

    t.bigint :discover_sales_cents, default: 0, null: false
    t.bigint :discover_refunds_cents, default: 0, null: false
    t.bigint :discover_disputes_cents, default: 0, null: false
    t.bigint :discover_dispute_reversals_cents, default: 0, null: false
    t.bigint :discover_net_revenue_cents, as: "discover_sales_cents - discover_refunds_cents - discover_disputes_cents + discover_dispute_reversals_cents", stored: true, null: false

    t.integer :sales_count, default: 0, null: false
    t.integer :full_refunds_count, default: 0, null: false
    t.integer :disputes_count, default: 0, null: false
    t.integer :dispute_reversals_count, default: 0, null: false

    t.integer :net_sales_count, as: "sales_count - full_refunds_count - disputes_count + dispute_reversals_count", stored: true, null: false

    t.integer :free_sales_count, default: 0, null: false

    t.integer :active_nonmemberships_count, default: 0, null: false
    t.integer :inactive_nonmemberships_count, default: 0, null: false
    t.integer :net_active_nonmemberships_count, as: "active_nonmemberships_count - inactive_nonmemberships_count", stored: true, null: false
    t.integer :active_memberships_count, default: 0, null: false
    t.integer :inactive_memberships_count, default: 0, null: false
    t.integer :net_active_memberships_count, as: "active_memberships_count - inactive_memberships_count", stored: true, null: false
    t.integer :net_active_sales_count, as: "net_active_nonmemberships_count + net_active_memberships_count", stored: true, null: false

    t.timestamps
  end

  def change
    create_table :product_daily_sales_stats do |t|
      t.bigint :seller_id, null: false
      t.bigint :product_id, null: false
      t.date :date, null: false

      set_up_common_columns(t)

      t.index [:product_id, :date], unique: true
      t.index [:seller_id, :date] # used when reingesting
      t.index :date # used for global sums
    end

    create_table :product_sales_stats do |t|
      t.bigint :seller_id, null: false
      t.bigint :product_id, null: false

      set_up_common_columns(t)

      t.index :seller_id
      t.index :product_id, unique: true
    end

    create_table :variant_daily_sales_stats do |t|
      t.bigint :seller_id, null: false
      t.bigint :product_id, null: false
      t.bigint :variant_id, null: false
      t.date :date, null: false

      set_up_common_columns(t)

      t.index [:variant_id, :date], unique: true
      t.index [:seller_id, :date] # used when reingesting
      t.index :date # used for global sums
      t.index :product_id
    end

    create_table :variant_sales_stats do |t|
      t.bigint :seller_id, null: false
      t.bigint :product_id, null: false
      t.bigint :variant_id, null: false

      set_up_common_columns(t)

      t.index :seller_id
      t.index :product_id
      t.index :variant_id, unique: true
    end

    create_table :seller_daily_sales_stats do |t|
      t.bigint :seller_id, null: false
      t.date :date, null: false

      set_up_common_columns(t)

      t.index [:seller_id, :date], unique: true
      t.index :date # used for global sums
    end

    create_table :seller_sales_stats do |t|
      t.bigint :seller_id, null: false

      set_up_common_columns(t)

      t.index :seller_id, unique: true
    end
  end
end
