# frozen_string_literal: true

class RemoveSalesStatsTables < ActiveRecord::Migration[7.1]
  def up
    drop_table :product_daily_sales_stats, if_exists: true
    drop_table :product_sales_stats, if_exists: true
    drop_table :seller_daily_sales_stats, if_exists: true
    drop_table :seller_sales_stats, if_exists: true
    drop_table :variant_daily_sales_stats, if_exists: true
    drop_table :variant_sales_stats, if_exists: true
  end

  def down
    create_table "product_daily_sales_stats", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: true do |t|
      t.bigint "seller_id", null: false
      t.bigint "product_id", null: false
      t.date "date", null: false
      t.bigint "sales_cents", default: 0, null: false
      t.bigint "refunds_cents", default: 0, null: false
      t.bigint "disputes_cents", default: 0, null: false
      t.bigint "dispute_reversals_cents", default: 0, null: false
      t.virtual "net_revenue_cents", type: :bigint, null: false, as: "(((`sales_cents` - `refunds_cents`) - `disputes_cents`) + `dispute_reversals_cents`)", stored: true
      t.bigint "fees_cents", default: 0, null: false
      t.bigint "fees_refunds_cents", default: 0, null: false
      t.bigint "fees_disputes_cents", default: 0, null: false
      t.bigint "fees_dispute_reversals_cents", default: 0, null: false
      t.virtual "net_fees_cents", type: :bigint, null: false, as: "(((`fees_cents` - `fees_refunds_cents`) - `fees_disputes_cents`) + `fees_dispute_reversals_cents`)", stored: true
      t.bigint "affiliate_sales_cents", default: 0, null: false
      t.bigint "affiliate_refunds_cents", default: 0, null: false
      t.bigint "affiliate_disputes_cents", default: 0, null: false
      t.bigint "affiliate_dispute_reversals_cents", default: 0, null: false
      t.virtual "net_affiliate_revenue_cents", type: :bigint, null: false, as: "(((`affiliate_sales_cents` - `affiliate_refunds_cents`) - `affiliate_disputes_cents`) + `affiliate_dispute_reversals_cents`)", stored: true
      t.virtual "adjusted_net_revenue_cents", type: :bigint, null: false, as: "((`net_revenue_cents` - `net_fees_cents`) - `net_affiliate_revenue_cents`)", stored: true
      t.bigint "discover_sales_cents", default: 0, null: false
      t.bigint "discover_refunds_cents", default: 0, null: false
      t.bigint "discover_disputes_cents", default: 0, null: false
      t.bigint "discover_dispute_reversals_cents", default: 0, null: false
      t.virtual "discover_net_revenue_cents", type: :bigint, null: false, as: "(((`discover_sales_cents` - `discover_refunds_cents`) - `discover_disputes_cents`) + `discover_dispute_reversals_cents`)", stored: true
      t.integer "sales_count", default: 0, null: false
      t.integer "full_refunds_count", default: 0, null: false
      t.integer "disputes_count", default: 0, null: false
      t.integer "dispute_reversals_count", default: 0, null: false
      t.virtual "net_sales_count", type: :integer, null: false, as: "(((`sales_count` - `full_refunds_count`) - `disputes_count`) + `dispute_reversals_count`)", stored: true
      t.integer "free_sales_count", default: 0, null: false
      t.integer "active_nonmemberships_count", default: 0, null: false
      t.integer "inactive_nonmemberships_count", default: 0, null: false
      t.virtual "net_active_nonmemberships_count", type: :integer, null: false, as: "(`active_nonmemberships_count` - `inactive_nonmemberships_count`)", stored: true
      t.integer "active_memberships_count", default: 0, null: false
      t.integer "inactive_memberships_count", default: 0, null: false
      t.virtual "net_active_memberships_count", type: :integer, null: false, as: "(`active_memberships_count` - `inactive_memberships_count`)", stored: true
      t.virtual "net_active_sales_count", type: :integer, null: false, as: "(`net_active_nonmemberships_count` + `net_active_memberships_count`)", stored: true
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["date"], name: "index_product_daily_sales_stats_on_date"
      t.index ["product_id", "date"], name: "index_product_daily_sales_stats_on_product_id_and_date", unique: true
      t.index ["seller_id", "date"], name: "index_product_daily_sales_stats_on_seller_id_and_date"
    end

    create_table "product_sales_stats", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: true do |t|
      t.bigint "seller_id", null: false
      t.bigint "product_id", null: false
      t.bigint "sales_cents", default: 0, null: false
      t.bigint "refunds_cents", default: 0, null: false
      t.bigint "disputes_cents", default: 0, null: false
      t.bigint "dispute_reversals_cents", default: 0, null: false
      t.virtual "net_revenue_cents", type: :bigint, null: false, as: "(((`sales_cents` - `refunds_cents`) - `disputes_cents`) + `dispute_reversals_cents`)", stored: true
      t.bigint "fees_cents", default: 0, null: false
      t.bigint "fees_refunds_cents", default: 0, null: false
      t.bigint "fees_disputes_cents", default: 0, null: false
      t.bigint "fees_dispute_reversals_cents", default: 0, null: false
      t.virtual "net_fees_cents", type: :bigint, null: false, as: "(((`fees_cents` - `fees_refunds_cents`) - `fees_disputes_cents`) + `fees_dispute_reversals_cents`)", stored: true
      t.bigint "affiliate_sales_cents", default: 0, null: false
      t.bigint "affiliate_refunds_cents", default: 0, null: false
      t.bigint "affiliate_disputes_cents", default: 0, null: false
      t.bigint "affiliate_dispute_reversals_cents", default: 0, null: false
      t.virtual "net_affiliate_revenue_cents", type: :bigint, null: false, as: "(((`affiliate_sales_cents` - `affiliate_refunds_cents`) - `affiliate_disputes_cents`) + `affiliate_dispute_reversals_cents`)", stored: true
      t.virtual "adjusted_net_revenue_cents", type: :bigint, null: false, as: "((`net_revenue_cents` - `net_fees_cents`) - `net_affiliate_revenue_cents`)", stored: true
      t.bigint "discover_sales_cents", default: 0, null: false
      t.bigint "discover_refunds_cents", default: 0, null: false
      t.bigint "discover_disputes_cents", default: 0, null: false
      t.bigint "discover_dispute_reversals_cents", default: 0, null: false
      t.virtual "discover_net_revenue_cents", type: :bigint, null: false, as: "(((`discover_sales_cents` - `discover_refunds_cents`) - `discover_disputes_cents`) + `discover_dispute_reversals_cents`)", stored: true
      t.integer "sales_count", default: 0, null: false
      t.integer "full_refunds_count", default: 0, null: false
      t.integer "disputes_count", default: 0, null: false
      t.integer "dispute_reversals_count", default: 0, null: false
      t.virtual "net_sales_count", type: :integer, null: false, as: "(((`sales_count` - `full_refunds_count`) - `disputes_count`) + `dispute_reversals_count`)", stored: true
      t.integer "free_sales_count", default: 0, null: false
      t.integer "active_nonmemberships_count", default: 0, null: false
      t.integer "inactive_nonmemberships_count", default: 0, null: false
      t.virtual "net_active_nonmemberships_count", type: :integer, null: false, as: "(`active_nonmemberships_count` - `inactive_nonmemberships_count`)", stored: true
      t.integer "active_memberships_count", default: 0, null: false
      t.integer "inactive_memberships_count", default: 0, null: false
      t.virtual "net_active_memberships_count", type: :integer, null: false, as: "(`active_memberships_count` - `inactive_memberships_count`)", stored: true
      t.virtual "net_active_sales_count", type: :integer, null: false, as: "(`net_active_nonmemberships_count` + `net_active_memberships_count`)", stored: true
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["product_id"], name: "index_product_sales_stats_on_product_id", unique: true
      t.index ["seller_id"], name: "index_product_sales_stats_on_seller_id"
    end

    create_table "seller_daily_sales_stats", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: true do |t|
      t.bigint "seller_id", null: false
      t.date "date", null: false
      t.bigint "sales_cents", default: 0, null: false
      t.bigint "refunds_cents", default: 0, null: false
      t.bigint "disputes_cents", default: 0, null: false
      t.bigint "dispute_reversals_cents", default: 0, null: false
      t.virtual "net_revenue_cents", type: :bigint, null: false, as: "(((`sales_cents` - `refunds_cents`) - `disputes_cents`) + `dispute_reversals_cents`)", stored: true
      t.bigint "fees_cents", default: 0, null: false
      t.bigint "fees_refunds_cents", default: 0, null: false
      t.bigint "fees_disputes_cents", default: 0, null: false
      t.bigint "fees_dispute_reversals_cents", default: 0, null: false
      t.virtual "net_fees_cents", type: :bigint, null: false, as: "(((`fees_cents` - `fees_refunds_cents`) - `fees_disputes_cents`) + `fees_dispute_reversals_cents`)", stored: true
      t.bigint "affiliate_sales_cents", default: 0, null: false
      t.bigint "affiliate_refunds_cents", default: 0, null: false
      t.bigint "affiliate_disputes_cents", default: 0, null: false
      t.bigint "affiliate_dispute_reversals_cents", default: 0, null: false
      t.virtual "net_affiliate_revenue_cents", type: :bigint, null: false, as: "(((`affiliate_sales_cents` - `affiliate_refunds_cents`) - `affiliate_disputes_cents`) + `affiliate_dispute_reversals_cents`)", stored: true
      t.virtual "adjusted_net_revenue_cents", type: :bigint, null: false, as: "((`net_revenue_cents` - `net_fees_cents`) - `net_affiliate_revenue_cents`)", stored: true
      t.bigint "discover_sales_cents", default: 0, null: false
      t.bigint "discover_refunds_cents", default: 0, null: false
      t.bigint "discover_disputes_cents", default: 0, null: false
      t.bigint "discover_dispute_reversals_cents", default: 0, null: false
      t.virtual "discover_net_revenue_cents", type: :bigint, null: false, as: "(((`discover_sales_cents` - `discover_refunds_cents`) - `discover_disputes_cents`) + `discover_dispute_reversals_cents`)", stored: true
      t.integer "sales_count", default: 0, null: false
      t.integer "full_refunds_count", default: 0, null: false
      t.integer "disputes_count", default: 0, null: false
      t.integer "dispute_reversals_count", default: 0, null: false
      t.virtual "net_sales_count", type: :integer, null: false, as: "(((`sales_count` - `full_refunds_count`) - `disputes_count`) + `dispute_reversals_count`)", stored: true
      t.integer "free_sales_count", default: 0, null: false
      t.integer "active_nonmemberships_count", default: 0, null: false
      t.integer "inactive_nonmemberships_count", default: 0, null: false
      t.virtual "net_active_nonmemberships_count", type: :integer, null: false, as: "(`active_nonmemberships_count` - `inactive_nonmemberships_count`)", stored: true
      t.integer "active_memberships_count", default: 0, null: false
      t.integer "inactive_memberships_count", default: 0, null: false
      t.virtual "net_active_memberships_count", type: :integer, null: false, as: "(`active_memberships_count` - `inactive_memberships_count`)", stored: true
      t.virtual "net_active_sales_count", type: :integer, null: false, as: "(`net_active_nonmemberships_count` + `net_active_memberships_count`)", stored: true
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["date"], name: "index_seller_daily_sales_stats_on_date"
      t.index ["seller_id", "date"], name: "index_seller_daily_sales_stats_on_seller_id_and_date", unique: true
    end

    create_table "seller_sales_stats", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: true do |t|
      t.bigint "seller_id", null: false
      t.bigint "sales_cents", default: 0, null: false
      t.bigint "refunds_cents", default: 0, null: false
      t.bigint "disputes_cents", default: 0, null: false
      t.bigint "dispute_reversals_cents", default: 0, null: false
      t.virtual "net_revenue_cents", type: :bigint, null: false, as: "(((`sales_cents` - `refunds_cents`) - `disputes_cents`) + `dispute_reversals_cents`)", stored: true
      t.bigint "fees_cents", default: 0, null: false
      t.bigint "fees_refunds_cents", default: 0, null: false
      t.bigint "fees_disputes_cents", default: 0, null: false
      t.bigint "fees_dispute_reversals_cents", default: 0, null: false
      t.virtual "net_fees_cents", type: :bigint, null: false, as: "(((`fees_cents` - `fees_refunds_cents`) - `fees_disputes_cents`) + `fees_dispute_reversals_cents`)", stored: true
      t.bigint "affiliate_sales_cents", default: 0, null: false
      t.bigint "affiliate_refunds_cents", default: 0, null: false
      t.bigint "affiliate_disputes_cents", default: 0, null: false
      t.bigint "affiliate_dispute_reversals_cents", default: 0, null: false
      t.virtual "net_affiliate_revenue_cents", type: :bigint, null: false, as: "(((`affiliate_sales_cents` - `affiliate_refunds_cents`) - `affiliate_disputes_cents`) + `affiliate_dispute_reversals_cents`)", stored: true
      t.virtual "adjusted_net_revenue_cents", type: :bigint, null: false, as: "((`net_revenue_cents` - `net_fees_cents`) - `net_affiliate_revenue_cents`)", stored: true
      t.bigint "discover_sales_cents", default: 0, null: false
      t.bigint "discover_refunds_cents", default: 0, null: false
      t.bigint "discover_disputes_cents", default: 0, null: false
      t.bigint "discover_dispute_reversals_cents", default: 0, null: false
      t.virtual "discover_net_revenue_cents", type: :bigint, null: false, as: "(((`discover_sales_cents` - `discover_refunds_cents`) - `discover_disputes_cents`) + `discover_dispute_reversals_cents`)", stored: true
      t.integer "sales_count", default: 0, null: false
      t.integer "full_refunds_count", default: 0, null: false
      t.integer "disputes_count", default: 0, null: false
      t.integer "dispute_reversals_count", default: 0, null: false
      t.virtual "net_sales_count", type: :integer, null: false, as: "(((`sales_count` - `full_refunds_count`) - `disputes_count`) + `dispute_reversals_count`)", stored: true
      t.integer "free_sales_count", default: 0, null: false
      t.integer "active_nonmemberships_count", default: 0, null: false
      t.integer "inactive_nonmemberships_count", default: 0, null: false
      t.virtual "net_active_nonmemberships_count", type: :integer, null: false, as: "(`active_nonmemberships_count` - `inactive_nonmemberships_count`)", stored: true
      t.integer "active_memberships_count", default: 0, null: false
      t.integer "inactive_memberships_count", default: 0, null: false
      t.virtual "net_active_memberships_count", type: :integer, null: false, as: "(`active_memberships_count` - `inactive_memberships_count`)", stored: true
      t.virtual "net_active_sales_count", type: :integer, null: false, as: "(`net_active_nonmemberships_count` + `net_active_memberships_count`)", stored: true
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["seller_id"], name: "index_seller_sales_stats_on_seller_id", unique: true
    end

    create_table "variant_daily_sales_stats", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: true do |t|
      t.bigint "seller_id", null: false
      t.bigint "product_id", null: false
      t.bigint "variant_id", null: false
      t.date "date", null: false
      t.bigint "sales_cents", default: 0, null: false
      t.bigint "refunds_cents", default: 0, null: false
      t.bigint "disputes_cents", default: 0, null: false
      t.bigint "dispute_reversals_cents", default: 0, null: false
      t.virtual "net_revenue_cents", type: :bigint, null: false, as: "(((`sales_cents` - `refunds_cents`) - `disputes_cents`) + `dispute_reversals_cents`)", stored: true
      t.bigint "fees_cents", default: 0, null: false
      t.bigint "fees_refunds_cents", default: 0, null: false
      t.bigint "fees_disputes_cents", default: 0, null: false
      t.bigint "fees_dispute_reversals_cents", default: 0, null: false
      t.virtual "net_fees_cents", type: :bigint, null: false, as: "(((`fees_cents` - `fees_refunds_cents`) - `fees_disputes_cents`) + `fees_dispute_reversals_cents`)", stored: true
      t.bigint "affiliate_sales_cents", default: 0, null: false
      t.bigint "affiliate_refunds_cents", default: 0, null: false
      t.bigint "affiliate_disputes_cents", default: 0, null: false
      t.bigint "affiliate_dispute_reversals_cents", default: 0, null: false
      t.virtual "net_affiliate_revenue_cents", type: :bigint, null: false, as: "(((`affiliate_sales_cents` - `affiliate_refunds_cents`) - `affiliate_disputes_cents`) + `affiliate_dispute_reversals_cents`)", stored: true
      t.virtual "adjusted_net_revenue_cents", type: :bigint, null: false, as: "((`net_revenue_cents` - `net_fees_cents`) - `net_affiliate_revenue_cents`)", stored: true
      t.bigint "discover_sales_cents", default: 0, null: false
      t.bigint "discover_refunds_cents", default: 0, null: false
      t.bigint "discover_disputes_cents", default: 0, null: false
      t.bigint "discover_dispute_reversals_cents", default: 0, null: false
      t.virtual "discover_net_revenue_cents", type: :bigint, null: false, as: "(((`discover_sales_cents` - `discover_refunds_cents`) - `discover_disputes_cents`) + `discover_dispute_reversals_cents`)", stored: true
      t.integer "sales_count", default: 0, null: false
      t.integer "full_refunds_count", default: 0, null: false
      t.integer "disputes_count", default: 0, null: false
      t.integer "dispute_reversals_count", default: 0, null: false
      t.virtual "net_sales_count", type: :integer, null: false, as: "(((`sales_count` - `full_refunds_count`) - `disputes_count`) + `dispute_reversals_count`)", stored: true
      t.integer "free_sales_count", default: 0, null: false
      t.integer "active_nonmemberships_count", default: 0, null: false
      t.integer "inactive_nonmemberships_count", default: 0, null: false
      t.virtual "net_active_nonmemberships_count", type: :integer, null: false, as: "(`active_nonmemberships_count` - `inactive_nonmemberships_count`)", stored: true
      t.integer "active_memberships_count", default: 0, null: false
      t.integer "inactive_memberships_count", default: 0, null: false
      t.virtual "net_active_memberships_count", type: :integer, null: false, as: "(`active_memberships_count` - `inactive_memberships_count`)", stored: true
      t.virtual "net_active_sales_count", type: :integer, null: false, as: "(`net_active_nonmemberships_count` + `net_active_memberships_count`)", stored: true
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["date"], name: "index_variant_daily_sales_stats_on_date"
      t.index ["product_id"], name: "index_variant_daily_sales_stats_on_product_id"
      t.index ["seller_id", "date"], name: "index_variant_daily_sales_stats_on_seller_id_and_date"
      t.index ["variant_id", "date"], name: "index_variant_daily_sales_stats_on_variant_id_and_date", unique: true
    end

    create_table "variant_sales_stats", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: true do |t|
      t.bigint "seller_id", null: false
      t.bigint "product_id", null: false
      t.bigint "variant_id", null: false
      t.bigint "sales_cents", default: 0, null: false
      t.bigint "refunds_cents", default: 0, null: false
      t.bigint "disputes_cents", default: 0, null: false
      t.bigint "dispute_reversals_cents", default: 0, null: false
      t.virtual "net_revenue_cents", type: :bigint, null: false, as: "(((`sales_cents` - `refunds_cents`) - `disputes_cents`) + `dispute_reversals_cents`)", stored: true
      t.bigint "fees_cents", default: 0, null: false
      t.bigint "fees_refunds_cents", default: 0, null: false
      t.bigint "fees_disputes_cents", default: 0, null: false
      t.bigint "fees_dispute_reversals_cents", default: 0, null: false
      t.virtual "net_fees_cents", type: :bigint, null: false, as: "(((`fees_cents` - `fees_refunds_cents`) - `fees_disputes_cents`) + `fees_dispute_reversals_cents`)", stored: true
      t.bigint "affiliate_sales_cents", default: 0, null: false
      t.bigint "affiliate_refunds_cents", default: 0, null: false
      t.bigint "affiliate_disputes_cents", default: 0, null: false
      t.bigint "affiliate_dispute_reversals_cents", default: 0, null: false
      t.virtual "net_affiliate_revenue_cents", type: :bigint, null: false, as: "(((`affiliate_sales_cents` - `affiliate_refunds_cents`) - `affiliate_disputes_cents`) + `affiliate_dispute_reversals_cents`)", stored: true
      t.virtual "adjusted_net_revenue_cents", type: :bigint, null: false, as: "((`net_revenue_cents` - `net_fees_cents`) - `net_affiliate_revenue_cents`)", stored: true
      t.bigint "discover_sales_cents", default: 0, null: false
      t.bigint "discover_refunds_cents", default: 0, null: false
      t.bigint "discover_disputes_cents", default: 0, null: false
      t.bigint "discover_dispute_reversals_cents", default: 0, null: false
      t.virtual "discover_net_revenue_cents", type: :bigint, null: false, as: "(((`discover_sales_cents` - `discover_refunds_cents`) - `discover_disputes_cents`) + `discover_dispute_reversals_cents`)", stored: true
      t.integer "sales_count", default: 0, null: false
      t.integer "full_refunds_count", default: 0, null: false
      t.integer "disputes_count", default: 0, null: false
      t.integer "dispute_reversals_count", default: 0, null: false
      t.virtual "net_sales_count", type: :integer, null: false, as: "(((`sales_count` - `full_refunds_count`) - `disputes_count`) + `dispute_reversals_count`)", stored: true
      t.integer "free_sales_count", default: 0, null: false
      t.integer "active_nonmemberships_count", default: 0, null: false
      t.integer "inactive_nonmemberships_count", default: 0, null: false
      t.virtual "net_active_nonmemberships_count", type: :integer, null: false, as: "(`active_nonmemberships_count` - `inactive_nonmemberships_count`)", stored: true
      t.integer "active_memberships_count", default: 0, null: false
      t.integer "inactive_memberships_count", default: 0, null: false
      t.virtual "net_active_memberships_count", type: :integer, null: false, as: "(`active_memberships_count` - `inactive_memberships_count`)", stored: true
      t.virtual "net_active_sales_count", type: :integer, null: false, as: "(`net_active_nonmemberships_count` + `net_active_memberships_count`)", stored: true
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["product_id"], name: "index_variant_sales_stats_on_product_id"
      t.index ["seller_id"], name: "index_variant_sales_stats_on_seller_id"
      t.index ["variant_id"], name: "index_variant_sales_stats_on_variant_id", unique: true
    end
  end
end
