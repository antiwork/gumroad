# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2025_09_25_161102) do
  create_table "active_storage_attachments", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "name", limit: 191, null: false
    t.string "record_type", limit: 191, null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "key", limit: 191, null: false
    t.string "filename", limit: 191, null: false
    t.string "content_type", limit: 191
    t.text "metadata"
    t.bigint "byte_size", null: false
    t.string "checksum", limit: 191
    t.datetime "created_at", precision: nil, null: false
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "admin_action_call_infos", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "controller_name", null: false
    t.string "action_name", null: false
    t.integer "call_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["controller_name", "action_name"], name: "index_admin_action_call_infos_on_controller_name_and_action_name", unique: true
  end

  create_table "affiliate_credits", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "oauth_application_id"
    t.integer "basis_points"
    t.integer "amount_cents"
    t.integer "affiliate_user_id"
    t.integer "seller_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "purchase_id"
    t.integer "link_id"
    t.integer "affiliate_credit_success_balance_id"
    t.integer "affiliate_credit_chargeback_balance_id"
    t.integer "affiliate_credit_refund_balance_id"
    t.integer "affiliate_id"
    t.bigint "fee_cents", default: 0, null: false
    t.index ["affiliate_credit_chargeback_balance_id"], name: "idx_affiliate_credits_on_affiliate_credit_chargeback_balance_id"
    t.index ["affiliate_credit_refund_balance_id"], name: "index_affiliate_credits_on_affiliate_credit_refund_balance_id"
    t.index ["affiliate_credit_success_balance_id"], name: "index_affiliate_credits_on_affiliate_credit_success_balance_id"
    t.index ["affiliate_id"], name: "index_affiliate_credits_on_affiliate_id"
    t.index ["affiliate_user_id"], name: "index_affiliate_credits_on_affiliate_user_id"
    t.index ["link_id"], name: "index_affiliate_credits_on_link_id"
    t.index ["oauth_application_id"], name: "index_affiliate_credits_on_oauth_application_id"
    t.index ["purchase_id"], name: "index_affiliate_credits_on_purchase_id"
    t.index ["seller_id"], name: "index_affiliate_credits_on_seller_id"
  end

  create_table "affiliate_partial_refunds", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "amount_cents", default: 0
    t.integer "purchase_id", null: false
    t.integer "total_credit_cents", default: 0
    t.integer "affiliate_user_id"
    t.integer "seller_id"
    t.integer "affiliate_id"
    t.integer "balance_id"
    t.integer "affiliate_credit_id"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.bigint "fee_cents", default: 0
    t.index ["affiliate_credit_id"], name: "index_affiliate_partial_refunds_on_affiliate_credit_id"
    t.index ["affiliate_id"], name: "index_affiliate_partial_refunds_on_affiliate_id"
    t.index ["affiliate_user_id"], name: "index_affiliate_partial_refunds_on_affiliate_user_id"
    t.index ["balance_id"], name: "index_affiliate_partial_refunds_on_balance_id"
    t.index ["purchase_id"], name: "index_affiliate_partial_refunds_on_purchase_id"
    t.index ["seller_id"], name: "index_affiliate_partial_refunds_on_seller_id"
  end

  create_table "affiliate_requests", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "seller_id", null: false
    t.string "name", limit: 100, null: false
    t.string "email", null: false
    t.text "promotion_text", size: :medium, null: false
    t.string "locale", default: "en", null: false
    t.string "state"
    t.datetime "state_transitioned_at", precision: nil
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["seller_id"], name: "index_affiliate_requests_on_seller_id"
  end

  create_table "affiliates", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "seller_id"
    t.integer "affiliate_user_id"
    t.integer "affiliate_basis_points"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.datetime "deleted_at", precision: nil
    t.integer "flags", default: 0, null: false
    t.string "destination_url", limit: 2083
    t.string "type", null: false
    t.index ["affiliate_user_id"], name: "index_affiliates_on_affiliate_user_id"
    t.index ["seller_id"], name: "index_affiliates_on_seller_id"
  end

  create_table "affiliates_links", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "affiliate_id"
    t.integer "link_id"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.integer "affiliate_basis_points"
    t.string "destination_url"
    t.bigint "flags", default: 0, null: false
    t.index ["affiliate_id"], name: "index_affiliates_links_on_affiliate_id"
    t.index ["link_id"], name: "index_affiliates_links_on_link_id"
  end

  create_table "asset_previews", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "link_id"
    t.string "guid"
    t.text "oembed"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.datetime "deleted_at", precision: nil
    t.integer "position"
    t.string "unsplash_url"
    t.index ["deleted_at"], name: "index_asset_previews_on_deleted_at"
    t.index ["link_id"], name: "index_asset_previews_on_link_id"
  end

  create_table "audience_members", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "seller_id", null: false
    t.string "email", null: false
    t.json "details"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "customer", default: false, null: false
    t.boolean "follower", default: false, null: false
    t.boolean "affiliate", default: false, null: false
    t.integer "min_paid_cents"
    t.integer "max_paid_cents"
    t.datetime "min_created_at", precision: nil
    t.datetime "max_created_at", precision: nil
    t.datetime "min_purchase_created_at", precision: nil
    t.datetime "max_purchase_created_at", precision: nil
    t.datetime "follower_created_at", precision: nil
    t.datetime "min_affiliate_created_at", precision: nil
    t.datetime "max_affiliate_created_at", precision: nil
    t.index ["seller_id", "customer", "follower", "affiliate"], name: "idx_audience_on_seller_and_types"
    t.index ["seller_id", "email"], name: "index_audience_members_on_seller_id_and_email", unique: true
    t.index ["seller_id", "follower_created_at"], name: "idx_audience_on_seller_and_follower_created_at"
    t.index ["seller_id", "min_affiliate_created_at", "max_affiliate_created_at"], name: "idx_audience_on_seller_and_minmax_affiliate_created_at"
    t.index ["seller_id", "min_created_at", "max_created_at"], name: "idx_audience_on_seller_and_minmax_created_at"
    t.index ["seller_id", "min_paid_cents", "max_paid_cents"], name: "idx_audience_on_seller_and_minmax_paid_cents"
    t.index ["seller_id", "min_purchase_created_at", "max_purchase_created_at"], name: "idx_audience_on_seller_and_minmax_purchase_created_at"
  end

  create_table "australia_backtax_email_infos", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "user_id"
    t.string "email_name"
    t.datetime "sent_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_australia_backtax_email_infos_on_user_id"
  end

  create_table "backtax_agreements", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "jurisdiction"
    t.string "signature"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "flags", default: 0, null: false
    t.index ["user_id"], name: "index_backtax_agreements_on_user_id"
  end

  create_table "backtax_collections", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "backtax_agreement_id", null: false
    t.integer "amount_cents"
    t.integer "amount_cents_usd"
    t.string "currency"
    t.string "stripe_transfer_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["backtax_agreement_id"], name: "index_backtax_collections_on_backtax_agreement_id"
    t.index ["user_id"], name: "index_backtax_collections_on_user_id"
  end

  create_table "balance_transactions", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.integer "user_id"
    t.integer "merchant_account_id"
    t.integer "balance_id"
    t.integer "purchase_id"
    t.integer "dispute_id"
    t.integer "refund_id"
    t.integer "credit_id"
    t.datetime "occurred_at", precision: nil
    t.string "issued_amount_currency"
    t.integer "issued_amount_gross_cents"
    t.integer "issued_amount_net_cents"
    t.string "holding_amount_currency"
    t.integer "holding_amount_gross_cents"
    t.integer "holding_amount_net_cents"
    t.index ["balance_id"], name: "index_balance_transactions_on_balance_id"
    t.index ["credit_id"], name: "index_balance_transactions_on_credit_id"
    t.index ["dispute_id"], name: "index_balance_transactions_on_dispute_id"
    t.index ["merchant_account_id"], name: "index_balance_transactions_on_merchant_account_id"
    t.index ["purchase_id"], name: "index_balance_transactions_on_purchase_id"
    t.index ["refund_id"], name: "index_balance_transactions_on_refund_id"
    t.index ["user_id"], name: "index_balance_transactions_on_user_id"
  end

  create_table "balances", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "user_id"
    t.date "date"
    t.integer "amount_cents", default: 0
    t.string "state"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "merchant_account_id", default: 1
    t.string "currency", default: "usd"
    t.string "holding_currency", default: "usd"
    t.integer "holding_amount_cents", default: 0
    t.index ["user_id", "merchant_account_id", "date"], name: "index_on_user_merchant_account_date"
  end

  create_table "bank_accounts", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "user_id"
    t.string "bank_number"
    t.binary "account_number"
    t.string "state"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "account_number_last_four"
    t.string "account_holder_full_name"
    t.datetime "deleted_at", precision: nil
    t.string "type", default: "AchAccount"
    t.string "branch_code"
    t.string "account_type"
    t.string "stripe_bank_account_id"
    t.string "stripe_fingerprint"
    t.string "stripe_connect_account_id"
    t.string "country", limit: 191
    t.integer "credit_card_id"
    t.index ["user_id"], name: "index_ach_accounts_on_user_id"
  end

  create_table "banks", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "routing_number"
    t.string "name"
    t.index ["routing_number"], name: "index_banks_on_routing_number"
  end

  create_table "base_variant_integrations", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "base_variant_id", null: false
    t.bigint "integration_id", null: false
    t.datetime "deleted_at", precision: nil
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["base_variant_id"], name: "index_base_variant_integrations_on_base_variant_id"
    t.index ["integration_id"], name: "index_base_variant_integrations_on_integration_id"
  end

  create_table "base_variants", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "variant_category_id"
    t.integer "price_difference_cents"
    t.string "name"
    t.integer "max_purchase_count"
    t.datetime "deleted_at", precision: nil
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.string "type", default: "Variant"
    t.integer "link_id"
    t.string "custom_sku"
    t.integer "flags", default: 0, null: false
    t.string "description"
    t.integer "position_in_category"
    t.boolean "customizable_price"
    t.date "subscription_price_change_effective_date"
    t.text "subscription_price_change_message", size: :long
    t.integer "duration_in_minutes"
    t.index ["link_id"], name: "index_base_variants_on_link_id"
    t.index ["variant_category_id"], name: "index_variants_on_variant_category_id"
  end

  create_table "base_variants_product_files", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "base_variant_id"
    t.integer "product_file_id"
    t.index ["base_variant_id"], name: "index_base_variants_product_files_on_base_variant_id"
    t.index ["product_file_id"], name: "index_base_variants_product_files_on_product_file_id"
  end

  create_table "base_variants_purchases", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "purchase_id"
    t.integer "base_variant_id"
    t.index ["base_variant_id"], name: "index_purchases_variants_on_variant_id"
    t.index ["purchase_id"], name: "index_purchases_variants_on_purchase_id"
  end

  create_table "blocked_customer_objects", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "seller_id", null: false
    t.string "object_type", null: false
    t.string "object_value", null: false
    t.string "buyer_email"
    t.datetime "blocked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["buyer_email"], name: "index_blocked_customer_objects_on_buyer_email"
    t.index ["seller_id", "object_type", "object_value"], name: "idx_blocked_customer_objects_on_seller_and_object_type_and_value", unique: true
    t.index ["seller_id"], name: "index_blocked_customer_objects_on_seller_id"
  end

  create_table "bundle_product_purchases", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "bundle_purchase_id", null: false
    t.bigint "product_purchase_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bundle_purchase_id"], name: "index_bundle_product_purchases_on_bundle_purchase_id"
    t.index ["product_purchase_id"], name: "index_bundle_product_purchases_on_product_purchase_id"
  end

  create_table "bundle_products", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "bundle_id", null: false
    t.bigint "product_id", null: false
    t.bigint "variant_id"
    t.integer "quantity", null: false
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "position"
    t.index ["bundle_id"], name: "index_bundle_products_on_bundle_id"
    t.index ["product_id"], name: "index_bundle_products_on_product_id"
    t.index ["variant_id"], name: "index_bundle_products_on_variant_id"
  end

  create_table "cached_sales_related_products_infos", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "product_id", null: false
    t.json "counts"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["product_id"], name: "index_cached_sales_related_products_infos_on_product_id", unique: true
  end

  create_table "call_availabilities", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "call_id", null: false
    t.datetime "start_time"
    t.datetime "end_time"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["call_id"], name: "index_call_availabilities_on_call_id"
  end

  create_table "call_limitation_infos", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "call_id", null: false
    t.integer "minimum_notice_in_minutes"
    t.integer "maximum_calls_per_day"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["call_id"], name: "index_call_limitation_infos_on_call_id"
  end

  create_table "calls", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "purchase_id"
    t.string "call_url", limit: 1024
    t.datetime "start_time"
    t.datetime "end_time"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "google_calendar_event_id"
    t.index ["purchase_id"], name: "index_calls_on_purchase_id"
  end

  create_table "cart_products", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "cart_id", null: false
    t.bigint "product_id", null: false
    t.bigint "option_id"
    t.bigint "affiliate_id"
    t.bigint "accepted_offer_id"
    t.bigint "price", null: false
    t.integer "quantity", null: false
    t.string "recurrence"
    t.string "recommended_by"
    t.boolean "rent", default: false, null: false
    t.json "url_parameters"
    t.text "referrer", size: :long, null: false
    t.string "recommender_model_name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "deleted_at"
    t.datetime "call_start_time"
    t.json "accepted_offer_details"
    t.boolean "pay_in_installments", default: false, null: false
    t.index ["cart_id", "product_id", "deleted_at"], name: "index_cart_products_on_cart_id_and_product_id_and_deleted_at", unique: true
    t.index ["cart_id"], name: "index_cart_products_on_cart_id"
    t.index ["product_id"], name: "index_cart_products_on_product_id"
  end

  create_table "carts", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "user_id"
    t.bigint "order_id"
    t.text "return_url", size: :long
    t.json "discount_codes"
    t.boolean "reject_ppp_discount", default: false, null: false
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "email"
    t.string "browser_guid"
    t.string "ip_address"
    t.index ["browser_guid"], name: "index_carts_on_browser_guid"
    t.index ["created_at"], name: "index_carts_on_created_at"
    t.index ["email"], name: "index_carts_on_email"
    t.index ["order_id"], name: "index_carts_on_order_id"
    t.index ["updated_at"], name: "index_carts_on_updated_at"
    t.index ["user_id"], name: "index_carts_on_user_id"
  end

  create_table "charge_purchases", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "charge_id", null: false
    t.bigint "purchase_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["charge_id"], name: "index_charge_purchases_on_charge_id"
    t.index ["purchase_id"], name: "index_charge_purchases_on_purchase_id"
  end

  create_table "charges", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "order_id", null: false
    t.bigint "seller_id", null: false
    t.string "processor"
    t.string "processor_transaction_id"
    t.string "payment_method_fingerprint"
    t.bigint "credit_card_id"
    t.bigint "merchant_account_id"
    t.bigint "amount_cents"
    t.bigint "gumroad_amount_cents"
    t.bigint "processor_fee_cents"
    t.string "processor_fee_currency"
    t.string "paypal_order_id"
    t.string "stripe_payment_intent_id"
    t.string "stripe_setup_intent_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "disputed_at"
    t.datetime "dispute_reversed_at"
    t.bigint "flags", default: 0, null: false
    t.index ["credit_card_id"], name: "index_charges_on_credit_card_id"
    t.index ["merchant_account_id"], name: "index_charges_on_merchant_account_id"
    t.index ["order_id"], name: "index_charges_on_order_id"
    t.index ["paypal_order_id"], name: "index_charges_on_paypal_order_id", unique: true
    t.index ["processor_transaction_id"], name: "index_charges_on_processor_transaction_id", unique: true
    t.index ["seller_id"], name: "index_charges_on_seller_id"
  end

  create_table "collaborator_invitations", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "collaborator_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["collaborator_id"], name: "index_collaborator_invitations_on_collaborator_id", unique: true
  end

  create_table "comments", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "commentable_id"
    t.string "commentable_type"
    t.bigint "author_id"
    t.string "author_name"
    t.text "content", size: :medium
    t.string "comment_type"
    t.text "json_data", size: :medium
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.datetime "deleted_at", precision: nil
    t.bigint "purchase_id"
    t.string "ancestry"
    t.integer "ancestry_depth", default: 0, null: false
    t.index ["ancestry"], name: "index_comments_on_ancestry"
    t.index ["commentable_id", "commentable_type"], name: "index_comments_on_commentable_id_and_commentable_type"
    t.index ["purchase_id"], name: "index_comments_on_purchase_id"
  end

  create_table "commission_files", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "url", limit: 1024
    t.bigint "commission_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["commission_id"], name: "index_commission_files_on_commission_id"
  end

  create_table "commissions", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "status"
    t.bigint "deposit_purchase_id"
    t.bigint "completion_purchase_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["completion_purchase_id"], name: "index_commissions_on_completion_purchase_id"
    t.index ["deposit_purchase_id"], name: "index_commissions_on_deposit_purchase_id"
  end

  create_table "communities", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "resource_type", null: false
    t.bigint "resource_id", null: false
    t.bigint "seller_id", null: false
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["deleted_at"], name: "index_communities_on_deleted_at"
    t.index ["resource_type", "resource_id", "seller_id", "deleted_at"], name: "idx_on_resource_type_resource_id_seller_id_deleted__23a67b41cb", unique: true
    t.index ["resource_type", "resource_id"], name: "index_communities_on_resource"
    t.index ["seller_id"], name: "index_communities_on_seller_id"
  end

  create_table "community_chat_messages", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "community_id", null: false
    t.bigint "user_id", null: false
    t.text "content", size: :long, null: false
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["community_id"], name: "index_community_chat_messages_on_community_id"
    t.index ["deleted_at"], name: "index_community_chat_messages_on_deleted_at"
    t.index ["user_id"], name: "index_community_chat_messages_on_user_id"
  end

  create_table "community_chat_recap_runs", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "recap_frequency", null: false
    t.datetime "from_date", null: false
    t.datetime "to_date", null: false
    t.integer "recaps_count", default: 0, null: false
    t.datetime "finished_at"
    t.datetime "notified_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["recap_frequency", "from_date", "to_date"], name: "idx_on_recap_frequency_from_date_to_date_2ed29d569d", unique: true
    t.index ["recap_frequency"], name: "index_community_chat_recap_runs_on_recap_frequency"
  end

  create_table "community_chat_recaps", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "community_chat_recap_run_id", null: false
    t.bigint "community_id"
    t.bigint "seller_id"
    t.integer "summarized_message_count", default: 0, null: false
    t.text "summary", size: :long
    t.string "status", default: "pending", null: false
    t.string "error_message"
    t.integer "input_token_count", default: 0, null: false
    t.integer "output_token_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["community_chat_recap_run_id"], name: "index_community_chat_recaps_on_community_chat_recap_run_id"
    t.index ["community_id"], name: "index_community_chat_recaps_on_community_id"
    t.index ["seller_id"], name: "index_community_chat_recaps_on_seller_id"
    t.index ["status"], name: "index_community_chat_recaps_on_status"
  end

  create_table "community_notification_settings", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "seller_id", null: false
    t.string "recap_frequency"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["recap_frequency"], name: "index_community_notification_settings_on_recap_frequency"
    t.index ["seller_id"], name: "index_community_notification_settings_on_seller_id"
    t.index ["user_id", "seller_id"], name: "index_community_notification_settings_on_user_id_and_seller_id", unique: true
    t.index ["user_id"], name: "index_community_notification_settings_on_user_id"
  end

  create_table "computed_sales_analytics_days", id: :integer, charset: "latin1", force: :cascade do |t|
    t.string "key", limit: 191, null: false
    t.text "data", size: :medium
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["key"], name: "index_computed_sales_analytics_days_on_key", unique: true
  end

  create_table "consumption_events", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "product_file_id"
    t.bigint "url_redirect_id"
    t.bigint "purchase_id"
    t.string "event_type"
    t.string "platform"
    t.integer "flags", default: 0, null: false
    t.text "json_data"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.bigint "link_id"
    t.datetime "consumed_at", precision: nil
    t.integer "media_location_basis_points"
    t.index ["link_id"], name: "index_consumption_events_on_link_id"
    t.index ["product_file_id"], name: "index_consumption_events_on_product_file_id"
    t.index ["purchase_id"], name: "index_consumption_events_on_purchase_id"
  end

  create_table "credit_cards", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "card_type"
    t.integer "expiry_month"
    t.integer "expiry_year"
    t.string "stripe_customer_id"
    t.string "visual"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.string "stripe_fingerprint"
    t.boolean "cvc_check_failed"
    t.string "card_country"
    t.string "stripe_card_id"
    t.string "card_bin"
    t.integer "preorder_id"
    t.string "card_data_handling_mode"
    t.string "charge_processor_id"
    t.string "braintree_customer_id"
    t.string "funding_type", limit: 191
    t.string "paypal_billing_agreement_id", limit: 191
    t.string "processor_payment_method_id"
    t.json "json_data"
    t.index ["preorder_id"], name: "index_credit_cards_on_preorder_id"
    t.index ["stripe_fingerprint"], name: "index_credit_cards_on_stripe_fingerprint"
  end

  create_table "credits", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "user_id"
    t.integer "amount_cents"
    t.integer "balance_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "crediting_user_id"
    t.integer "chargebacked_purchase_id"
    t.integer "merchant_account_id", default: 1
    t.integer "dispute_id"
    t.integer "returned_payment_id"
    t.integer "refund_id"
    t.integer "financing_paydown_purchase_id"
    t.integer "fee_retention_refund_id"
    t.bigint "backtax_agreement_id"
    t.text "json_data"
    t.index ["balance_id"], name: "index_credits_on_balance_id"
    t.index ["dispute_id"], name: "index_credits_on_dispute_id"
  end

  create_table "custom_domains", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "user_id"
    t.string "domain"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.datetime "ssl_certificate_issued_at", precision: nil
    t.datetime "deleted_at", precision: nil
    t.string "state", default: "unverified", null: false
    t.integer "failed_verification_attempts_count", default: 0, null: false
    t.bigint "product_id"
    t.index ["domain"], name: "index_custom_domains_on_domain"
    t.index ["product_id"], name: "index_custom_domains_on_product_id"
    t.index ["ssl_certificate_issued_at"], name: "index_custom_domains_on_ssl_certificate_issued_at"
    t.index ["user_id"], name: "index_custom_domains_on_user_id"
  end

  create_table "custom_fields", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "field_type"
    t.string "name"
    t.boolean "required", default: false
    t.boolean "global", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "seller_id", null: false
    t.bigint "flags", default: 0, null: false
    t.index ["seller_id"], name: "index_custom_fields_on_seller_id"
  end

  create_table "custom_fields_products", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "custom_field_id", null: false
    t.bigint "product_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["custom_field_id"], name: "index_custom_fields_products_on_custom_field_id"
    t.index ["product_id"], name: "index_custom_fields_products_on_product_id"
  end

  create_table "devices", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "token", null: false
    t.string "app_version"
    t.string "device_type", default: "ios", null: false
    t.integer "user_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "app_type", default: "consumer", null: false
    t.index ["app_type", "user_id"], name: "index_devices_on_app_type_and_user_id"
    t.index ["token", "device_type"], name: "index_devices_on_token_and_device_type", unique: true
    t.index ["user_id"], name: "index_devices_on_user_id"
  end

  create_table "discover_search_suggestions", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "discover_search_id"
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["discover_search_id"], name: "index_discover_search_suggestions_on_discover_search_id"
  end

  create_table "discover_searches", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "query"
    t.bigint "taxonomy_id"
    t.bigint "user_id"
    t.string "ip_address"
    t.string "browser_guid"
    t.boolean "autocomplete", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "clicked_resource_type"
    t.bigint "clicked_resource_id"
    t.index ["browser_guid"], name: "index_discover_searches_on_browser_guid"
    t.index ["clicked_resource_type", "clicked_resource_id"], name: "index_discover_searches_on_clicked_resource"
    t.index ["created_at"], name: "index_discover_searches_on_created_at"
    t.index ["ip_address"], name: "index_discover_searches_on_ip_address"
    t.index ["query"], name: "index_discover_searches_on_query"
    t.index ["user_id"], name: "index_discover_searches_on_user_id"
  end

  create_table "dispute_evidences", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "dispute_id", null: false
    t.datetime "purchased_at"
    t.string "customer_purchase_ip"
    t.string "customer_email"
    t.string "customer_name"
    t.string "billing_address"
    t.string "shipping_address"
    t.datetime "shipped_at"
    t.string "shipping_carrier"
    t.string "shipping_tracking_number"
    t.text "uncategorized_text"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "product_description"
    t.text "cancellation_policy_disclosure"
    t.text "refund_policy_disclosure"
    t.text "cancellation_rebuttal"
    t.text "refund_refusal_explanation"
    t.datetime "seller_contacted_at"
    t.datetime "seller_submitted_at"
    t.datetime "resolved_at"
    t.string "resolution", default: "unknown"
    t.string "error_message"
    t.text "access_activity_log"
    t.text "reason_for_winning"
    t.index ["dispute_id"], name: "index_dispute_evidences_on_dispute_id", unique: true
    t.index ["resolved_at"], name: "index_dispute_evidences_on_resolved_at"
  end

  create_table "disputes", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "purchase_id"
    t.string "charge_processor_id"
    t.string "charge_processor_dispute_id"
    t.string "reason"
    t.string "state"
    t.datetime "initiated_at", precision: nil
    t.datetime "closed_at", precision: nil
    t.datetime "formalized_at", precision: nil
    t.datetime "won_at", precision: nil
    t.datetime "lost_at", precision: nil
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.integer "service_charge_id"
    t.bigint "seller_id"
    t.datetime "event_created_at"
    t.bigint "charge_id"
    t.index ["charge_id"], name: "index_disputes_on_charge_id"
    t.index ["purchase_id"], name: "index_disputes_on_purchase_id"
    t.index ["seller_id", "event_created_at"], name: "index_disputes_on_seller_id_and_event_created_at"
    t.index ["seller_id", "lost_at"], name: "index_disputes_on_seller_id_and_lost_at"
    t.index ["seller_id", "won_at"], name: "index_disputes_on_seller_id_and_won_at"
    t.index ["service_charge_id"], name: "index_disputes_on_service_charge_id"
  end

  create_table "dropbox_files", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "state"
    t.string "dropbox_url", limit: 2000
    t.datetime "expires_at", precision: nil
    t.datetime "deleted_at", precision: nil
    t.integer "user_id"
    t.integer "product_file_id"
    t.integer "link_id"
    t.text "json_data", size: :medium
    t.string "s3_url", limit: 2000
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.index ["link_id"], name: "index_dropbox_files_on_link_id"
    t.index ["product_file_id"], name: "index_dropbox_files_on_product_file_id"
    t.index ["user_id"], name: "index_dropbox_files_on_user_id"
  end

  create_table "email_info_charges", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "email_info_id", null: false
    t.bigint "charge_id", null: false
    t.index ["charge_id"], name: "index_email_info_charges_on_charge_id"
    t.index ["email_info_id"], name: "index_email_info_charges_on_email_info_id"
  end

  create_table "email_infos", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "purchase_id"
    t.bigint "installment_id"
    t.string "type"
    t.string "email_name"
    t.string "state"
    t.datetime "sent_at", precision: nil
    t.datetime "delivered_at", precision: nil
    t.datetime "opened_at", precision: nil
    t.index ["installment_id", "purchase_id"], name: "index_email_infos_on_installment_id_and_purchase_id"
    t.index ["purchase_id"], name: "index_email_infos_on_purchase_id"
  end

  create_table "events", id: :integer, charset: "latin1", force: :cascade do |t|
    t.integer "visit_id"
    t.string "ip_address"
    t.string "event_name"
    t.integer "user_id"
    t.integer "link_id"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.string "referrer"
    t.string "parent_referrer"
    t.string "language"
    t.string "browser"
    t.boolean "is_mobile", default: false
    t.string "email"
    t.integer "purchase_id"
    t.integer "price_cents"
    t.integer "credit_card_id"
    t.string "card_type"
    t.string "card_visual"
    t.string "purchase_state"
    t.string "billing_zip"
    t.boolean "chargeback", default: false
    t.boolean "refunded", default: false
    t.string "view_url"
    t.string "fingerprint"
    t.string "ip_country"
    t.float "ip_longitude"
    t.float "ip_latitude"
    t.boolean "is_modal"
    t.text "friend_actions"
    t.string "browser_fingerprint"
    t.string "browser_plugins"
    t.string "browser_guid"
    t.string "referrer_domain"
    t.string "ip_state"
    t.string "active_test_path_assignments"
    t.integer "service_charge_id"
    t.index ["browser_guid"], name: "index_events_on_browser_guid"
    t.index ["created_at"], name: "index_events_on_created_at"
    t.index ["event_name", "link_id", "created_at"], name: "index_events_on_event_name_and_link_id"
    t.index ["ip_address"], name: "index_events_on_ip_address"
    t.index ["link_id"], name: "index_events_on_link_id"
    t.index ["purchase_id"], name: "index_events_on_purchase_id"
    t.index ["service_charge_id"], name: "index_events_on_service_charge_id"
    t.index ["user_id"], name: "index_events_on_user_id"
    t.index ["visit_id"], name: "index_events_on_visit_id"
  end

  create_table "followers", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "followed_id", null: false
    t.string "email"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.integer "follower_user_id"
    t.string "source"
    t.integer "source_product_id"
    t.datetime "confirmed_at", precision: nil
    t.datetime "deleted_at", precision: nil
    t.index ["email", "followed_id"], name: "index_followers_on_email_and_followed_id", unique: true
    t.index ["followed_id", "confirmed_at"], name: "index_followers_on_followed_id_and_confirmed_at"
    t.index ["followed_id", "email"], name: "index_followers_on_followed_id_and_email"
  end

  create_table "friendly_id_slugs", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "slug", limit: 191, null: false
    t.integer "sluggable_id", null: false
    t.string "sluggable_type", limit: 50
    t.string "scope", limit: 191
    t.datetime "created_at", precision: nil
    t.index ["slug", "sluggable_type", "scope"], name: "index_friendly_id_slugs_on_slug_and_sluggable_type_and_scope", unique: true, length: { slug: 70, scope: 70 }
    t.index ["slug", "sluggable_type"], name: "index_friendly_id_slugs_on_slug_and_sluggable_type", length: { slug: 140 }
    t.index ["sluggable_type", "sluggable_id"], name: "index_friendly_id_slugs_on_sluggable_type_and_sluggable_id"
  end

  create_table "gifts", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "giftee_purchase_id"
    t.bigint "gifter_purchase_id"
    t.bigint "link_id"
    t.string "state"
    t.text "gift_note", size: :long
    t.string "giftee_email"
    t.string "gifter_email"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "flags", default: 0, null: false
    t.index ["giftee_email"], name: "index_gifts_on_giftee_email"
    t.index ["giftee_purchase_id"], name: "index_gifts_on_giftee_purchase_id"
    t.index ["gifter_email"], name: "index_gifts_on_gifter_email"
    t.index ["gifter_purchase_id"], name: "index_gifts_on_gifter_purchase_id"
  end

  create_table "gumroad_daily_analytics", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.datetime "period_ended_at", null: false
    t.integer "gumroad_price_cents", null: false
    t.integer "gumroad_fee_cents", null: false
    t.integer "creators_with_sales", null: false
    t.integer "gumroad_discover_price_cents", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["period_ended_at"], name: "index_gumroad_daily_analytics_on_period_ended_at"
  end

  create_table "imported_customers", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "email"
    t.datetime "purchase_date", precision: nil
    t.integer "link_id"
    t.integer "importing_user_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.datetime "deleted_at", precision: nil
    t.index ["email"], name: "index_imported_customers_on_email"
    t.index ["importing_user_id"], name: "index_imported_customers_on_importing_user_id"
    t.index ["link_id", "purchase_date"], name: "index_imported_customers_on_link_id_and_purchase_date"
    t.index ["link_id"], name: "index_imported_customers_on_link_id"
  end

  create_table "installment_events", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "event_id"
    t.integer "installment_id"
    t.index ["event_id"], name: "index_installment_events_on_event_id"
    t.index ["installment_id", "event_id"], name: "index_installment_events_on_installment_id_and_event_id", unique: true
  end

  create_table "installment_rules", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "installment_id"
    t.integer "delayed_delivery_time"
    t.datetime "to_be_published_at", precision: nil
    t.integer "version", default: 0, null: false
    t.datetime "deleted_at", precision: nil
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.string "time_period"
    t.index ["installment_id"], name: "index_installment_rules_on_installment_id", unique: true
  end

  create_table "installments", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "link_id"
    t.text "message", size: :long
    t.text "url", size: :long
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "name"
    t.datetime "published_at", precision: nil
    t.datetime "deleted_at", precision: nil
    t.integer "flags", default: 0, null: false
    t.integer "seller_id"
    t.string "installment_type"
    t.text "json_data", size: :medium
    t.integer "customer_count"
    t.integer "workflow_id"
    t.string "call_to_action_text", limit: 2083
    t.string "call_to_action_url", limit: 2083
    t.string "cover_image_url"
    t.integer "base_variant_id"
    t.string "slug"
    t.integer "installment_events_count", default: 0
    t.index ["base_variant_id"], name: "index_installments_on_base_variant_id"
    t.index ["created_at"], name: "index_installments_on_created_at"
    t.index ["link_id"], name: "index_installments_on_link_id"
    t.index ["seller_id", "link_id"], name: "index_installments_on_seller_id_and_link_id"
    t.index ["slug"], name: "index_installments_on_slug", unique: true
    t.index ["workflow_id"], name: "index_installments_on_workflow_id"
  end

  create_table "integrations", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "api_key"
    t.text "json_data"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "flags", default: 0, null: false
    t.string "type"
  end

  create_table "invites", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "sender_id"
    t.string "receiver_email"
    t.integer "receiver_id"
    t.string "invite_state"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["receiver_id"], name: "index_invites_on_receiver_id", unique: true
    t.index ["sender_id"], name: "index_invites_on_sender_id"
  end

  create_table "large_sellers", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "sales_count", default: 0, null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["updated_at"], name: "index_large_sellers_on_updated_at"
    t.index ["user_id"], name: "index_large_sellers_on_user_id", unique: true
  end

  create_table "last_read_community_chat_messages", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "community_id", null: false
    t.bigint "community_chat_message_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["community_chat_message_id"], name: "idx_on_community_chat_message_id_f9e10450e2"
    t.index ["community_id"], name: "index_last_read_community_chat_messages_on_community_id"
    t.index ["user_id", "community_id"], name: "idx_on_user_id_community_id_45efa2a41c", unique: true
    t.index ["user_id"], name: "index_last_read_community_chat_messages_on_user_id"
  end

  create_table "legacy_permalinks", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "permalink", null: false
    t.bigint "product_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["permalink"], name: "index_legacy_permalinks_on_permalink", unique: true
    t.index ["product_id"], name: "index_legacy_permalinks_on_product_id"
  end

  create_table "licenses", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "link_id"
    t.integer "purchase_id"
    t.string "serial"
    t.datetime "trial_expires_at", precision: nil
    t.integer "uses", default: 0
    t.string "json_data"
    t.datetime "deleted_at", precision: nil
    t.integer "flags", default: 0
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "imported_customer_id"
    t.datetime "disabled_at", precision: nil
    t.index ["imported_customer_id"], name: "index_licenses_on_imported_customer_id"
    t.index ["link_id"], name: "index_licenses_on_link_id"
    t.index ["purchase_id"], name: "index_licenses_on_purchase_id"
    t.index ["serial"], name: "index_licenses_on_serial", unique: true
  end

  create_table "links", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "user_id"
    t.string "name", null: false
    t.string "unique_permalink"
    t.text "preview_url", size: :medium
    t.text "description", size: :medium
    t.integer "purchase_type", default: 0
    t.datetime "created_at", precision: nil
    t.datetime "updated_at"
    t.datetime "purchase_disabled_at", precision: nil
    t.datetime "deleted_at", precision: nil
    t.integer "price_cents"
    t.string "price_currency_type", default: "usd"
    t.boolean "customizable_price"
    t.integer "max_purchase_count"
    t.integer "bad_card_counter", default: 0
    t.boolean "require_shipping", default: false
    t.datetime "last_partner_sync", precision: nil
    t.text "preview_oembed", size: :medium
    t.boolean "showcaseable", default: false
    t.text "custom_receipt", size: :medium
    t.string "custom_filetype"
    t.string "filetype", default: "link"
    t.string "filegroup", default: "url"
    t.bigint "size"
    t.integer "bitrate"
    t.integer "framerate"
    t.integer "pagelength"
    t.integer "duration"
    t.integer "width"
    t.integer "height"
    t.string "custom_permalink"
    t.string "common_color"
    t.integer "suggested_price_cents"
    t.datetime "banned_at", precision: nil
    t.integer "risk_score"
    t.datetime "risk_score_updated_at", precision: nil
    t.boolean "draft", default: false
    t.bigint "flags", default: 0, null: false
    t.integer "subscription_duration"
    t.text "json_data", size: :medium
    t.string "external_mapping_id"
    t.bigint "affiliate_application_id"
    t.integer "rental_price_cents"
    t.integer "duration_in_months"
    t.datetime "migrated_to_tiered_pricing_at", precision: nil
    t.integer "free_trial_duration_unit"
    t.integer "free_trial_duration_amount"
    t.datetime "content_updated_at", precision: nil
    t.bigint "taxonomy_id"
    t.string "native_type", default: "digital", null: false
    t.integer "discover_fee_per_thousand", default: 100, null: false
    t.string "support_email"
    t.index ["banned_at"], name: "index_links_on_banned_at"
    t.index ["custom_permalink"], name: "index_links_on_custom_permalink", length: 191
    t.index ["deleted_at"], name: "index_links_on_deleted_at"
    t.index ["showcaseable"], name: "index_links_on_showcaseable"
    t.index ["taxonomy_id"], name: "index_links_on_taxonomy_id"
    t.index ["unique_permalink"], name: "index_links_on_unique_permalink", length: 191
    t.index ["user_id", "updated_at"], name: "index_links_on_user_id_and_updated_at"
    t.index ["user_id"], name: "index_links_on_user_id"
  end

  create_table "media_locations", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "product_file_id", null: false
    t.bigint "url_redirect_id", null: false
    t.bigint "purchase_id", null: false
    t.bigint "product_id", null: false
    t.datetime "consumed_at", precision: nil
    t.string "platform"
    t.integer "location", null: false
    t.integer "content_length"
    t.string "unit"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["product_file_id"], name: "index_media_locations_on_product_file_id"
    t.index ["product_id", "updated_at"], name: "index_media_locations_on_product_id_and_updated_at"
    t.index ["purchase_id", "product_file_id", "consumed_at"], name: "index_media_locations_on_purchase_id_product_file_id_consumed_at"
    t.index ["purchase_id"], name: "index_media_locations_on_purchase_id"
  end

  create_table "merchant_accounts", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "user_id"
    t.string "acquirer_id"
    t.string "acquirer_merchant_id"
    t.string "charge_processor_id"
    t.string "charge_processor_merchant_id"
    t.text "json_data"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.datetime "deleted_at", precision: nil
    t.datetime "charge_processor_verified_at", precision: nil
    t.string "country", default: "US"
    t.string "currency", default: "usd"
    t.datetime "charge_processor_deleted_at", precision: nil
    t.datetime "charge_processor_alive_at", precision: nil
    t.index ["charge_processor_merchant_id"], name: "index_merchant_accounts_on_charge_processor_merchant_id"
    t.index ["user_id"], name: "index_merchant_accounts_on_user_id"
  end

  create_table "oauth_access_grants", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "resource_owner_id", null: false
    t.integer "application_id", null: false
    t.string "token", null: false
    t.integer "expires_in", null: false
    t.string "redirect_uri", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "revoked_at", precision: nil
    t.string "scopes", default: "", null: false
    t.index ["created_at"], name: "index_oauth_access_grants_on_created_at"
    t.index ["token"], name: "index_oauth_access_grants_on_token", unique: true
  end

  create_table "oauth_access_tokens", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "resource_owner_id"
    t.integer "application_id", null: false
    t.string "token", null: false
    t.string "refresh_token"
    t.integer "expires_in"
    t.datetime "revoked_at", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.string "scopes"
    t.index ["refresh_token"], name: "index_oauth_access_tokens_on_refresh_token", unique: true
    t.index ["resource_owner_id"], name: "index_oauth_access_tokens_on_resource_owner_id"
    t.index ["token"], name: "index_oauth_access_tokens_on_token", unique: true
  end

  create_table "oauth_applications", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "name", null: false
    t.string "uid", null: false
    t.string "secret", null: false
    t.string "redirect_uri", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "owner_id"
    t.string "owner_type", default: "User"
    t.integer "affiliate_basis_points"
    t.datetime "deleted_at", precision: nil
    t.string "scopes", default: "", null: false
    t.boolean "confidential", default: false, null: false
    t.index ["owner_id", "owner_type"], name: "index_oauth_applications_on_owner_id_and_owner_type"
    t.index ["uid"], name: "index_oauth_applications_on_uid", unique: true
  end

  create_table "offer_codes", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "link_id"
    t.string "name"
    t.integer "amount_cents"
    t.integer "max_purchase_count"
    t.datetime "deleted_at", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "amount_percentage"
    t.integer "user_id", null: false
    t.string "currency_type"
    t.string "code"
    t.boolean "universal", default: false, null: false
    t.datetime "valid_at", precision: nil
    t.datetime "expires_at", precision: nil
    t.integer "minimum_quantity"
    t.integer "duration_in_months"
    t.integer "minimum_amount_cents"
    t.bigint "flags", default: 0, null: false
    t.index ["code", "link_id"], name: "index_offer_codes_on_code_and_link_id"
    t.index ["link_id"], name: "index_offer_codes_on_link_id"
    t.index ["name", "link_id"], name: "index_offer_codes_on_name_and_link_id", length: { name: 191 }
    t.index ["universal"], name: "index_offer_codes_on_universal"
    t.index ["user_id"], name: "index_offer_codes_on_user_id"
  end

  create_table "offer_codes_products", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "offer_code_id"
    t.bigint "product_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["offer_code_id"], name: "index_offer_codes_products_on_offer_code_id"
    t.index ["product_id"], name: "index_offer_codes_products_on_product_id"
  end

  create_table "order_purchases", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "order_id", null: false
    t.bigint "purchase_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_order_purchases_on_order_id"
    t.index ["purchase_id"], name: "index_order_purchases_on_purchase_id"
  end

  create_table "orders", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "purchaser_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "flags", default: 0, null: false
    t.datetime "review_reminder_scheduled_at"
    t.index ["purchaser_id"], name: "index_orders_on_purchaser_id"
  end

  create_table "payment_options", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "subscription_id"
    t.integer "price_id"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.datetime "deleted_at", precision: nil
    t.integer "flags", default: 0, null: false
    t.bigint "product_installment_plan_id"
    t.index ["price_id"], name: "index_payment_options_on_price_id"
    t.index ["product_installment_plan_id"], name: "index_payment_options_on_product_installment_plan_id"
    t.index ["subscription_id"], name: "index_payment_options_on_subscription_id"
  end

  create_table "payments", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "user_id"
    t.string "state"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.string "txn_id"
    t.integer "processor_fee_cents"
    t.string "correlation_id"
    t.string "processor"
    t.bigint "amount_cents"
    t.string "payment_address"
    t.date "payout_period_end_date"
    t.bigint "bank_account_id"
    t.integer "amount_cents_in_local_currency"
    t.string "stripe_connect_account_id"
    t.string "stripe_transfer_id"
    t.string "stripe_internal_transfer_id"
    t.string "currency", default: "usd"
    t.integer "flags", default: 0, null: false
    t.text "json_data"
    t.string "failure_reason", limit: 191
    t.string "processor_reversing_payout_id"
    t.index ["stripe_transfer_id"], name: "index_payments_on_stripe_transfer_id"
    t.index ["user_id"], name: "index_payments_on_user_id"
  end

  create_table "payments_balances", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "payment_id"
    t.integer "balance_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["balance_id"], name: "index_payments_balances_on_balance_id"
    t.index ["payment_id"], name: "index_payments_balances_on_payment_id"
  end

  create_table "post_email_blasts", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "post_id", null: false
    t.bigint "seller_id", null: false
    t.datetime "requested_at"
    t.datetime "started_at"
    t.datetime "first_email_delivered_at"
    t.datetime "last_email_delivered_at"
    t.integer "delivery_count", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "completed_at"
    t.index ["post_id", "requested_at"], name: "index_post_email_blasts_on_post_id_and_requested_at"
    t.index ["requested_at"], name: "index_post_email_blasts_on_requested_at"
    t.index ["seller_id", "requested_at"], name: "index_post_email_blasts_on_seller_id_and_requested_at"
  end

  create_table "preorder_links", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "link_id"
    t.string "state"
    t.datetime "release_at", precision: nil
    t.string "url"
    t.string "custom_filetype"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["link_id"], name: "index_preorder_links_on_link_id"
  end

  create_table "preorders", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "preorder_link_id", null: false
    t.integer "seller_id", null: false
    t.integer "purchaser_id"
    t.string "state", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["preorder_link_id"], name: "index_preorders_on_preorder_link_id"
    t.index ["purchaser_id"], name: "index_preorders_on_purchaser_id"
    t.index ["seller_id"], name: "index_preorders_on_seller_id"
  end

  create_table "prices", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "link_id"
    t.integer "price_cents", default: 0, null: false
    t.string "currency", default: "usd"
    t.string "recurrence"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.datetime "deleted_at", precision: nil
    t.integer "flags", default: 0, null: false
    t.integer "variant_id"
    t.integer "suggested_price_cents"
    t.index ["link_id"], name: "index_prices_on_link_id"
    t.index ["variant_id"], name: "index_prices_on_variant_id"
  end

  create_table "processor_payment_intents", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "purchase_id", null: false
    t.string "intent_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["intent_id"], name: "index_processor_payment_intents_on_intent_id"
    t.index ["purchase_id"], name: "index_processor_payment_intents_on_purchase_id", unique: true
  end

  create_table "product_cached_values", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "product_id", null: false
    t.boolean "expired", default: false, null: false
    t.integer "successful_sales_count"
    t.integer "remaining_for_sale_count"
    t.decimal "monthly_recurring_revenue", precision: 10, scale: 2
    t.decimal "revenue_pending", precision: 10, scale: 2
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "total_usd_cents", default: 0
    t.index ["expired"], name: "index_product_cached_values_on_expired"
    t.index ["product_id"], name: "index_product_cached_values_on_product_id"
  end

  create_table "product_files", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "link_id"
    t.string "url", limit: 1024
    t.string "filetype"
    t.string "filegroup"
    t.bigint "size"
    t.integer "bitrate"
    t.integer "framerate"
    t.integer "pagelength"
    t.integer "duration"
    t.integer "width"
    t.integer "height"
    t.bigint "flags", default: 0, null: false
    t.text "json_data", size: :long
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "position"
    t.bigint "installment_id"
    t.string "display_name", limit: 1024
    t.datetime "deleted_from_cdn_at"
    t.text "description"
    t.bigint "folder_id"
    t.boolean "stampable_pdf"
    t.index ["deleted_at"], name: "index_product_files_on_deleted_at"
    t.index ["deleted_from_cdn_at"], name: "index_product_files_on_deleted_from_cdn_at"
    t.index ["installment_id"], name: "index_product_files_on_installment_id"
    t.index ["link_id"], name: "index_product_files_on_link_id"
    t.index ["url"], name: "index_product_files_on_url", length: 768
  end

  create_table "product_files_archives", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.datetime "deleted_at"
    t.bigint "link_id"
    t.bigint "installment_id"
    t.string "product_files_archive_state"
    t.datetime "created_at"
    t.datetime "updated_at"
    t.string "url", limit: 1024
    t.datetime "deleted_from_cdn_at"
    t.bigint "variant_id"
    t.string "digest"
    t.string "folder_id"
    t.index ["deleted_at"], name: "index_product_files_archives_on_deleted_at"
    t.index ["deleted_from_cdn_at"], name: "index_product_files_archives_on_deleted_from_cdn_at"
    t.index ["folder_id"], name: "index_product_files_archives_on_folder_id"
    t.index ["installment_id"], name: "index_product_files_archives_on_installment_id"
    t.index ["link_id"], name: "index_product_files_archives_on_link_id"
    t.index ["variant_id"], name: "index_product_files_archives_on_variant_id"
  end

  create_table "product_files_files_archives", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "product_file_id"
    t.integer "product_files_archive_id"
    t.index ["product_files_archive_id"], name: "index_product_files_files_archives_on_product_files_archive_id"
  end

  create_table "product_folders", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "product_id"
    t.string "name", null: false
    t.integer "position"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "deleted_at", precision: nil
    t.index ["product_id"], name: "index_product_folders_on_product_id"
  end

  create_table "product_installment_plans", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "link_id", null: false
    t.integer "number_of_installments", null: false
    t.string "recurrence", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "deleted_at"
    t.index ["deleted_at"], name: "index_product_installment_plans_on_deleted_at"
    t.index ["link_id"], name: "index_product_installment_plans_on_link_id"
  end

  create_table "product_integrations", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "product_id", null: false
    t.bigint "integration_id", null: false
    t.datetime "deleted_at", precision: nil
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["integration_id"], name: "index_product_integrations_on_integration_id"
    t.index ["product_id"], name: "index_product_integrations_on_product_id"
  end

  create_table "product_review_responses", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "product_review_id", null: false
    t.text "message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["product_review_id"], name: "index_product_review_responses_on_product_review_id"
    t.index ["user_id"], name: "index_product_review_responses_on_user_id"
  end

  create_table "product_review_stats", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "link_id"
    t.integer "reviews_count", default: 0, null: false
    t.float "average_rating", default: 0.0, null: false
    t.integer "ratings_of_one_count", default: 0
    t.integer "ratings_of_two_count", default: 0
    t.integer "ratings_of_three_count", default: 0
    t.integer "ratings_of_four_count", default: 0
    t.integer "ratings_of_five_count", default: 0
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["link_id"], name: "index_product_review_stats_on_link_id", unique: true
  end

  create_table "product_review_videos", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "product_review_id", null: false
    t.string "approval_status", default: "pending_review"
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["deleted_at"], name: "index_product_review_videos_on_deleted_at"
    t.index ["product_review_id"], name: "index_product_review_videos_on_product_review_id"
  end

  create_table "product_reviews", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "purchase_id"
    t.integer "rating"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.bigint "link_id"
    t.text "message"
    t.virtual "has_message", type: :boolean, null: false, as: "if((`message` is null),false,true)", stored: true
    t.datetime "deleted_at"
    t.index ["link_id", "has_message", "created_at"], name: "idx_on_link_id_has_message_created_at_2fcf6c0c64"
    t.index ["purchase_id"], name: "index_product_reviews_on_purchase_id", unique: true
  end

  create_table "product_taggings", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "tag_id"
    t.integer "product_id"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.index ["product_id"], name: "index_product_taggings_on_product_id"
    t.index ["tag_id"], name: "index_product_taggings_on_tag_id"
  end

  create_table "public_files", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "seller_id"
    t.string "resource_type", null: false
    t.bigint "resource_id", null: false
    t.string "public_id", null: false
    t.string "display_name", null: false
    t.string "original_file_name", null: false
    t.string "file_type"
    t.string "file_group"
    t.datetime "deleted_at"
    t.datetime "scheduled_for_deletion_at"
    t.text "json_data"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["deleted_at"], name: "index_public_files_on_deleted_at"
    t.index ["file_group"], name: "index_public_files_on_file_group"
    t.index ["file_type"], name: "index_public_files_on_file_type"
    t.index ["public_id"], name: "index_public_files_on_public_id", unique: true
    t.index ["resource_type", "resource_id"], name: "index_public_files_on_resource"
    t.index ["scheduled_for_deletion_at"], name: "index_public_files_on_scheduled_for_deletion_at"
    t.index ["seller_id"], name: "index_public_files_on_seller_id"
  end

  create_table "purchase_custom_field_files", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "url"
    t.bigint "purchase_custom_field_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["purchase_custom_field_id"], name: "index_purchase_custom_field_files_on_purchase_custom_field_id"
  end

  create_table "purchase_custom_fields", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "purchase_id", null: false
    t.string "field_type", null: false
    t.string "name", null: false
    t.text "value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "bundle_product_id"
    t.bigint "custom_field_id"
    t.bigint "flags", default: 0, null: false
    t.index ["custom_field_id"], name: "index_purchase_custom_fields_on_custom_field_id"
    t.index ["purchase_id"], name: "index_purchase_custom_fields_on_purchase_id"
  end

  create_table "purchase_early_fraud_warnings", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "purchase_id"
    t.string "processor_id", null: false
    t.bigint "dispute_id"
    t.bigint "refund_id"
    t.string "fraud_type", null: false
    t.boolean "actionable", null: false
    t.string "charge_risk_level", null: false
    t.datetime "processor_created_at", null: false
    t.string "resolution", default: "unknown"
    t.datetime "resolved_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "resolution_message"
    t.bigint "charge_id"
    t.index ["charge_id"], name: "index_purchase_early_fraud_warnings_on_charge_id", unique: true
    t.index ["processor_id"], name: "index_purchase_early_fraud_warnings_on_processor_id", unique: true
    t.index ["purchase_id"], name: "index_purchase_early_fraud_warnings_on_purchase_id", unique: true
  end

  create_table "purchase_integrations", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "purchase_id", null: false
    t.bigint "integration_id", null: false
    t.datetime "deleted_at", precision: nil
    t.string "discord_user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["integration_id"], name: "index_purchase_integrations_on_integration_id"
    t.index ["purchase_id"], name: "index_purchase_integrations_on_purchase_id"
  end

  create_table "purchase_offer_code_discounts", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "purchase_id", null: false
    t.bigint "offer_code_id", null: false
    t.integer "offer_code_amount", null: false
    t.boolean "offer_code_is_percent", default: false, null: false
    t.integer "pre_discount_minimum_price_cents", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "duration_in_months"
    t.index ["offer_code_id"], name: "index_purchase_offer_code_discounts_on_offer_code_id"
    t.index ["purchase_id"], name: "index_purchase_offer_code_discounts_on_purchase_id", unique: true
  end

  create_table "purchase_refund_policies", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "purchase_id", null: false
    t.string "title", null: false
    t.text "fine_print"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "max_refund_period_in_days"
    t.index ["purchase_id"], name: "index_purchase_refund_policies_on_purchase_id"
  end

  create_table "purchase_sales_tax_infos", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "purchase_id"
    t.string "elected_country_code"
    t.string "card_country_code"
    t.string "ip_country_code"
    t.string "country_code"
    t.string "postal_code"
    t.string "ip_address"
    t.string "business_vat_id", limit: 191
    t.string "state_code"
    t.index ["purchase_id"], name: "index_purchase_sales_tax_infos_on_purchase_id"
  end

  create_table "purchase_taxjar_infos", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "purchase_id", null: false
    t.decimal "combined_tax_rate", precision: 8, scale: 7
    t.decimal "county_tax_rate", precision: 8, scale: 7
    t.decimal "city_tax_rate", precision: 8, scale: 7
    t.decimal "state_tax_rate", precision: 8, scale: 7
    t.string "jurisdiction_state"
    t.string "jurisdiction_county"
    t.string "jurisdiction_city"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "gst_tax_rate", precision: 8, scale: 7
    t.decimal "pst_tax_rate", precision: 8, scale: 7
    t.decimal "qst_tax_rate", precision: 8, scale: 7
    t.index ["purchase_id"], name: "index_purchase_taxjar_infos_on_purchase_id"
  end

  create_table "purchase_wallet_types", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "purchase_id", null: false
    t.string "wallet_type", null: false
    t.index ["purchase_id"], name: "index_purchase_wallet_types_on_purchase_id", unique: true
    t.index ["wallet_type"], name: "index_purchase_wallet_types_on_wallet_type"
  end

  create_table "purchases", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "seller_id"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.integer "fee_cents"
    t.bigint "link_id"
    t.text "email"
    t.integer "price_cents"
    t.integer "displayed_price_cents"
    t.string "displayed_price_currency_type", default: "usd"
    t.string "rate_converted_to_usd"
    t.string "street_address"
    t.string "city"
    t.string "state"
    t.string "zip_code"
    t.string "country"
    t.string "full_name"
    t.bigint "credit_card_id"
    t.bigint "purchaser_id"
    t.string "purchaser_type", default: "User"
    t.string "session_id"
    t.string "ip_address"
    t.boolean "is_mobile"
    t.boolean "stripe_refunded"
    t.string "stripe_transaction_id"
    t.string "stripe_fingerprint"
    t.string "stripe_card_id"
    t.boolean "can_contact", default: true
    t.string "referrer"
    t.string "stripe_status"
    t.text "variants"
    t.datetime "chargeback_date", precision: nil
    t.boolean "webhook_failed", default: false
    t.boolean "failed", default: false
    t.string "card_type"
    t.string "card_visual"
    t.string "purchase_state"
    t.integer "processor_fee_cents"
    t.datetime "succeeded_at", precision: nil
    t.string "card_country"
    t.string "stripe_error_code"
    t.string "browser_guid"
    t.string "error_code"
    t.string "card_bin"
    t.text "custom_fields"
    t.string "ip_country"
    t.string "ip_state"
    t.bigint "purchase_success_balance_id"
    t.bigint "purchase_chargeback_balance_id"
    t.bigint "purchase_refund_balance_id"
    t.bigint "flags", default: 0, null: false
    t.bigint "offer_code_id"
    t.bigint "subscription_id"
    t.bigint "preorder_id"
    t.integer "card_expiry_month"
    t.integer "card_expiry_year"
    t.integer "tax_cents", default: 0
    t.integer "affiliate_credit_cents", default: 0
    t.string "credit_card_zipcode"
    t.string "json_data"
    t.string "card_data_handling_mode"
    t.string "charge_processor_id"
    t.integer "total_transaction_cents"
    t.integer "gumroad_tax_cents"
    t.bigint "zip_tax_rate_id"
    t.integer "quantity", default: 1, null: false
    t.bigint "merchant_account_id"
    t.integer "shipping_cents", default: 0
    t.bigint "affiliate_id"
    t.string "processor_fee_cents_currency", default: "usd"
    t.boolean "stripe_partially_refunded", default: false
    t.string "paypal_order_id", limit: 191
    t.boolean "rental_expired"
    t.string "processor_payment_intent_id"
    t.string "processor_setup_intent_id"
    t.bigint "price_id"
    t.string "recommended_by"
    t.datetime "deleted_at", precision: nil
    t.index ["affiliate_id", "created_at"], name: "index_purchases_on_affiliate_id_and_created_at"
    t.index ["browser_guid"], name: "index_purchases_on_browser_guid"
    t.index ["card_type", "card_visual", "created_at", "stripe_fingerprint"], name: "index_purchases_on_card_type_visual_date_fingerprint"
    t.index ["card_type", "card_visual", "stripe_fingerprint"], name: "index_purchases_on_card_type_visual_fingerprint"
    t.index ["created_at"], name: "index_purchases_on_created_at"
    t.index ["email"], name: "index_purchases_on_email_long", length: 191
    t.index ["full_name"], name: "index_purchases_on_full_name"
    t.index ["ip_address"], name: "index_purchases_on_ip_address"
    t.index ["link_id", "purchase_state", "created_at"], name: "index_purchases_on_link_id_and_purchase_state_and_created_at"
    t.index ["link_id"], name: "index_purchases_on_link_id"
    t.index ["offer_code_id"], name: "index_purchases_on_offer_code_id"
    t.index ["paypal_order_id"], name: "index_purchases_on_paypal_order_id"
    t.index ["preorder_id"], name: "index_purchases_on_preorder_id"
    t.index ["purchase_chargeback_balance_id"], name: "index_purchase_chargeback_balance_id"
    t.index ["purchase_refund_balance_id"], name: "index_purchase_refund_balance_id"
    t.index ["purchase_state", "created_at"], name: "index_purchases_on_purchase_state_and_created_at"
    t.index ["purchase_success_balance_id"], name: "index_purchase_success_balance_id"
    t.index ["purchaser_id"], name: "index_purchases_on_purchaser_id"
    t.index ["rental_expired"], name: "index_purchases_on_rental_expired"
    t.index ["seller_id", "chargeback_date"], name: "index_purchases_on_seller_id_and_chargeback_date"
    t.index ["seller_id", "purchase_state", "created_at"], name: "index_purchases_on_seller_id_and_purchase_state_and_created_at"
    t.index ["seller_id", "succeeded_at"], name: "index_purchases_on_seller_id_and_succeeded_at"
    t.index ["seller_id"], name: "index_purchases_on_seller_id"
    t.index ["stripe_fingerprint"], name: "index_purchases_on_stripe_fingerprint"
    t.index ["stripe_transaction_id"], name: "index_purchases_on_stripe_transaction_id"
    t.index ["subscription_id"], name: "index_purchases_on_subscription_id"
  end

  create_table "purchasing_power_parity_infos", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "purchase_id", null: false
    t.integer "factor"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["purchase_id"], name: "index_purchasing_power_parity_infos_on_purchase_id"
  end

  create_table "recommended_purchase_infos", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.integer "purchase_id"
    t.integer "recommended_link_id"
    t.integer "recommended_by_link_id"
    t.string "recommendation_type"
    t.integer "flags", default: 0, null: false
    t.integer "discover_fee_per_thousand"
    t.string "recommender_model_name"
    t.index ["purchase_id"], name: "index_recommended_purchase_infos_on_purchase_id"
    t.index ["recommended_by_link_id"], name: "index_recommended_purchase_infos_on_recommended_by_link_id"
    t.index ["recommended_link_id"], name: "index_recommended_purchase_infos_on_recommended_link_id"
  end

  create_table "recurring_services", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.integer "user_id"
    t.string "type", limit: 191
    t.integer "price_cents"
    t.integer "recurrence"
    t.datetime "failed_at", precision: nil
    t.datetime "cancelled_at", precision: nil
    t.string "state", limit: 191
    t.string "json_data", limit: 191
    t.index ["user_id"], name: "index_recurring_services_on_user_id"
  end

  create_table "refund_policies", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "seller_id", null: false
    t.bigint "product_id"
    t.string "title"
    t.text "fine_print"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "max_refund_period_in_days"
    t.index ["product_id"], name: "index_refund_policies_on_product_id", unique: true
    t.index ["seller_id"], name: "index_refund_policies_on_seller_id"
  end

  create_table "refunds", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "amount_cents", default: 0
    t.bigint "purchase_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.bigint "refunding_user_id"
    t.integer "creator_tax_cents"
    t.integer "gumroad_tax_cents"
    t.integer "total_transaction_cents"
    t.text "json_data", size: :medium
    t.bigint "link_id"
    t.string "status", limit: 191, default: "succeeded"
    t.string "processor_refund_id", limit: 191
    t.integer "fee_cents"
    t.bigint "flags", default: 0, null: false
    t.bigint "seller_id"
    t.index ["link_id"], name: "index_refunds_on_link_id"
    t.index ["processor_refund_id"], name: "index_refunds_on_processor_refund_id"
    t.index ["purchase_id"], name: "index_refunds_on_purchase_id"
    t.index ["seller_id", "created_at"], name: "index_refunds_on_seller_id_and_created_at"
  end

  create_table "resource_subscriptions", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "oauth_application_id", null: false
    t.integer "user_id", null: false
    t.string "resource_name", null: false
    t.string "post_url"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.datetime "deleted_at", precision: nil
    t.string "content_type", default: "application/x-www-form-urlencoded"
    t.index ["oauth_application_id"], name: "index_resource_subscriptions_on_oauth_application_id"
    t.index ["user_id"], name: "index_resource_subscriptions_on_user_id"
  end

  create_table "rich_contents", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "entity_id", null: false
    t.string "entity_type", null: false
    t.json "description", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "deleted_at", precision: nil
    t.string "title"
    t.integer "position", default: 0, null: false
    t.index ["entity_id", "entity_type"], name: "index_rich_contents_on_entity_id_and_entity_type"
  end

  create_table "sales_export_chunks", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "export_id", null: false
    t.text "purchase_ids", size: :long
    t.text "custom_fields"
    t.text "purchases_data", size: :long
    t.boolean "processed", default: false, null: false
    t.string "revision"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["export_id"], name: "index_sales_export_chunks_on_export_id"
  end

  create_table "sales_exports", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "recipient_id", null: false
    t.text "query"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["recipient_id"], name: "index_sales_exports_on_recipient_id"
  end

  create_table "sales_related_products_infos", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "smaller_product_id", null: false
    t.bigint "larger_product_id", null: false
    t.integer "sales_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["larger_product_id", "sales_count"], name: "index_larger_product_id_and_sales_count"
    t.index ["smaller_product_id", "larger_product_id"], name: "index_smaller_and_larger_product_ids", unique: true
    t.index ["smaller_product_id", "sales_count"], name: "index_smaller_product_id_and_sales_count"
  end

  create_table "self_service_affiliate_products", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "seller_id", null: false
    t.bigint "product_id", null: false
    t.boolean "enabled", default: false, null: false
    t.integer "affiliate_basis_points", null: false
    t.string "destination_url", limit: 2083
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["product_id"], name: "index_self_service_affiliate_products_on_product_id", unique: true
    t.index ["seller_id"], name: "index_self_service_affiliate_products_on_seller_id"
  end

  create_table "seller_profile_sections", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "seller_id", null: false
    t.string "header"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "flags", default: 0, null: false
    t.json "json_data"
    t.string "type", default: "SellerProfileProductsSection", null: false
    t.bigint "product_id"
    t.index ["product_id"], name: "index_seller_profile_sections_on_product_id"
    t.index ["seller_id"], name: "index_seller_profile_sections_on_seller_id"
  end

  create_table "seller_profiles", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "seller_id", null: false
    t.string "highlight_color"
    t.string "background_color"
    t.string "font"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.json "json_data"
    t.index ["seller_id"], name: "index_seller_profiles_on_seller_id"
  end

  create_table "sent_abandoned_cart_emails", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "cart_id", null: false
    t.bigint "installment_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["cart_id"], name: "index_sent_abandoned_cart_emails_on_cart_id"
    t.index ["installment_id"], name: "index_sent_abandoned_cart_emails_on_installment_id"
  end

  create_table "sent_email_infos", id: :integer, charset: "latin1", force: :cascade do |t|
    t.string "key", limit: 40, null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["created_at"], name: "index_sent_email_infos_on_created_at"
    t.index ["key"], name: "index_sent_email_infos_on_key", unique: true
  end

  create_table "sent_post_emails", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "post_id", null: false
    t.string "email", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["post_id", "email"], name: "index_sent_post_emails_on_post_id_and_email", unique: true
  end

  create_table "service_charges", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.integer "user_id"
    t.integer "recurring_service_id"
    t.integer "charge_cents"
    t.string "charge_cents_currency", limit: 191, default: "usd"
    t.string "state", limit: 191
    t.datetime "succeeded_at", precision: nil
    t.integer "credit_card_id"
    t.integer "card_expiry_month"
    t.integer "card_expiry_year"
    t.string "card_data_handling_mode", limit: 191
    t.string "card_bin", limit: 191
    t.string "card_type", limit: 191
    t.string "card_country", limit: 191
    t.string "card_zip_code", limit: 191
    t.string "card_visual", limit: 191
    t.string "charge_processor_id", limit: 191
    t.integer "charge_processor_fee_cents"
    t.string "charge_processor_fee_cents_currency", limit: 191, default: "usd"
    t.string "charge_processor_transaction_id", limit: 191
    t.string "charge_processor_fingerprint", limit: 191
    t.string "charge_processor_card_id", limit: 191
    t.string "charge_processor_status", limit: 191
    t.string "charge_processor_error_code", limit: 191
    t.boolean "charge_processor_refunded", default: false, null: false
    t.datetime "chargeback_date", precision: nil
    t.string "json_data", limit: 191
    t.string "error_code", limit: 191
    t.integer "merchant_account_id"
    t.string "browser_guid", limit: 191
    t.string "ip_address", limit: 191
    t.string "ip_country", limit: 191
    t.string "ip_state", limit: 191
    t.string "session_id", limit: 191
    t.integer "flags", default: 0, null: false
    t.string "discount_code", limit: 100
    t.string "processor_payment_intent_id"
    t.index ["card_type", "card_visual", "charge_processor_fingerprint"], name: "index_service_charges_on_card_type_visual_fingerprint"
    t.index ["card_type", "card_visual", "created_at", "charge_processor_fingerprint"], name: "index_service_charges_on_card_type_visual_date_fingerprint"
    t.index ["created_at"], name: "index_service_charges_on_created_at"
    t.index ["recurring_service_id"], name: "index_service_charges_on_recurring_service_id"
    t.index ["user_id"], name: "index_service_charges_on_user_id"
  end

  create_table "shipments", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "purchase_id"
    t.string "ship_state"
    t.datetime "shipped_at", precision: nil
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.string "tracking_number"
    t.string "carrier"
    t.string "tracking_url", limit: 2083
    t.index ["purchase_id"], name: "index_shipments_on_purchase_id"
  end

  create_table "shipping_destinations", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "link_id"
    t.integer "user_id"
    t.string "country_code", null: false
    t.integer "one_item_rate_cents", null: false
    t.integer "multiple_items_rate_cents", null: false
    t.integer "flags", default: 0, null: false
    t.text "json_data", size: :medium
    t.datetime "deleted_at", precision: nil
    t.datetime "created_at"
    t.datetime "updated_at"
    t.index ["link_id"], name: "index_shipping_destinations_on_link_id"
    t.index ["user_id"], name: "index_shipping_destinations_on_user_id"
  end

  create_table "signup_events", charset: "latin1", force: :cascade do |t|
    t.integer "visit_id"
    t.string "ip_address"
    t.integer "user_id"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.string "referrer"
    t.string "parent_referrer"
    t.string "language"
    t.string "browser"
    t.boolean "is_mobile", default: false
    t.string "email"
    t.string "view_url"
    t.string "fingerprint"
    t.string "ip_country"
    t.float "ip_longitude"
    t.float "ip_latitude"
    t.boolean "is_modal"
    t.string "browser_fingerprint"
    t.string "browser_plugins"
    t.string "browser_guid"
    t.string "referrer_domain"
    t.string "ip_state"
    t.string "active_test_path_assignments"
    t.string "event_name"
    t.integer "link_id"
    t.integer "purchase_id"
    t.integer "price_cents"
    t.integer "credit_card_id"
    t.string "card_type"
    t.string "card_visual"
    t.boolean "purchase_state", default: false
    t.string "billing_zip"
    t.boolean "chargeback", default: false
    t.boolean "refunded"
    t.index ["browser_guid"], name: "index_events_on_browser_guid"
    t.index ["created_at"], name: "index_events_on_created_at"
    t.index ["ip_address"], name: "index_events_on_ip_address"
    t.index ["user_id"], name: "index_events_on_user_id"
    t.index ["visit_id"], name: "index_events_on_visit_id"
  end

  create_table "skus_variants", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "variant_id"
    t.integer "sku_id"
    t.index ["sku_id"], name: "index_skus_variants_on_sku_id"
    t.index ["variant_id"], name: "index_skus_variants_on_variant_id"
  end

  create_table "staff_picked_products", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "product_id", null: false
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["product_id"], name: "index_staff_picked_products_on_product_id", unique: true
  end

  create_table "stamped_pdfs", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "url_redirect_id"
    t.bigint "product_file_id"
    t.string "url", limit: 1024
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "deleted_at"
    t.datetime "deleted_from_cdn_at"
    t.index ["created_at"], name: "index_stamped_pdfs_on_created_at"
    t.index ["deleted_at"], name: "index_stamped_pdfs_on_deleted_at"
    t.index ["deleted_from_cdn_at"], name: "index_stamped_pdfs_on_deleted_from_cdn_at"
    t.index ["product_file_id"], name: "index_stamped_pdfs_on_product_file_id"
    t.index ["url"], name: "index_stamped_pdfs_on_url", length: 768
    t.index ["url_redirect_id"], name: "index_stamped_pdfs_on_url_redirect_id"
  end

  create_table "stripe_apple_pay_domains", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "domain", null: false
    t.string "stripe_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["domain"], name: "index_stripe_apple_pay_domains_on_domain", unique: true
    t.index ["user_id"], name: "index_stripe_apple_pay_domains_on_user_id"
  end

  create_table "subscription_events", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "subscription_id", null: false
    t.integer "event_type", null: false
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "seller_id"
    t.index ["seller_id", "occurred_at"], name: "index_subscription_events_on_seller_id_and_occurred_at"
    t.index ["subscription_id"], name: "index_subscription_events_on_subscription_id"
  end

  create_table "subscription_plan_changes", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "subscription_id", null: false
    t.bigint "base_variant_id"
    t.string "recurrence", limit: 191, null: false
    t.integer "perceived_price_cents", null: false
    t.datetime "deleted_at", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "quantity", default: 1, null: false
    t.bigint "flags", default: 0, null: false
    t.date "effective_on"
    t.datetime "notified_subscriber_at"
    t.index ["base_variant_id"], name: "index_subscription_plan_changes_on_base_variant_id"
    t.index ["subscription_id"], name: "index_subscription_plan_changes_on_subscription_id"
  end

  create_table "subscriptions", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "link_id"
    t.bigint "user_id"
    t.datetime "cancelled_at"
    t.datetime "failed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "flags", default: 0, null: false
    t.datetime "user_requested_cancellation_at"
    t.integer "charge_occurrence_count"
    t.datetime "ended_at"
    t.bigint "last_payment_option_id"
    t.bigint "credit_card_id"
    t.datetime "deactivated_at"
    t.datetime "free_trial_ends_at"
    t.bigint "seller_id"
    t.string "token"
    t.datetime "token_expires_at"
    t.index ["cancelled_at"], name: "index_subscriptions_on_cancelled_at"
    t.index ["deactivated_at"], name: "index_subscriptions_on_deactivated_at"
    t.index ["ended_at"], name: "index_subscriptions_on_ended_at"
    t.index ["failed_at"], name: "index_subscriptions_on_failed_at"
    t.index ["link_id", "flags"], name: "index_subscriptions_on_link_id_and_flags"
    t.index ["link_id"], name: "index_subscriptions_on_link_id"
    t.index ["seller_id", "created_at"], name: "index_subscriptions_on_seller_id_and_created_at"
    t.index ["user_id"], name: "index_subscriptions_on_user_id"
  end

  create_table "subtitle_files", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "url", limit: 1024
    t.string "language"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "product_file_id"
    t.datetime "deleted_at"
    t.integer "size"
    t.datetime "deleted_from_cdn_at"
    t.index ["deleted_at"], name: "index_subtitle_files_on_deleted_at"
    t.index ["product_file_id"], name: "index_subtitle_files_on_product_file_id"
    t.index ["url"], name: "index_subtitle_files_on_url", length: 768
  end

  create_table "tags", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "name", limit: 100
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.string "humanized_name", limit: 191
    t.datetime "flagged_at", precision: nil
    t.index ["name"], name: "index_tags_on_name"
  end

  create_table "taxonomies", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "parent_id"
    t.string "slug", null: false
    t.index "(ifnull(`parent_id`,0)), `slug`", name: "index_taxonomies_on_parent_id_and_slug", unique: true
    t.index ["parent_id"], name: "index_taxonomies_on_parent_id"
  end

  create_table "taxonomy_hierarchies", id: false, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "ancestor_id", null: false
    t.bigint "descendant_id", null: false
    t.integer "generations", null: false
    t.index ["ancestor_id", "descendant_id", "generations"], name: "taxonomy_anc_desc_idx", unique: true
    t.index ["descendant_id"], name: "taxonomy_desc_idx"
  end

  create_table "taxonomy_stats", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "taxonomy_id", null: false
    t.integer "creators_count", default: 0, null: false
    t.integer "products_count", default: 0, null: false
    t.integer "sales_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "recent_sales_count", default: 0
    t.index ["taxonomy_id"], name: "index_taxonomy_stats_on_taxonomy_id"
  end

  create_table "team_invitations", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "seller_id", null: false
    t.string "email", null: false
    t.string "role", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "expires_at", null: false
    t.datetime "accepted_at"
    t.datetime "deleted_at"
    t.index ["seller_id"], name: "index_team_invitations_on_seller_id"
  end

  create_table "team_memberships", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "seller_id", null: false
    t.bigint "user_id", null: false
    t.string "role", null: false
    t.datetime "last_accessed_at", precision: nil
    t.datetime "deleted_at", precision: nil
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["seller_id"], name: "index_team_memberships_on_seller_id"
    t.index ["user_id"], name: "index_team_memberships_on_user_id"
  end

  create_table "third_party_analytics", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "user_id"
    t.integer "link_id"
    t.text "analytics_code"
    t.datetime "deleted_at", precision: nil
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.string "name"
    t.string "location", default: "receipt"
    t.index ["link_id"], name: "index_third_party_analytics_on_link_id"
    t.index ["user_id"], name: "index_third_party_analytics_on_user_id"
  end

  create_table "thumbnails", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "product_id"
    t.datetime "deleted_at", precision: nil
    t.string "guid"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "unsplash_url"
    t.index ["product_id"], name: "index_thumbnails_on_product_id"
  end

  create_table "tips", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "purchase_id", null: false
    t.integer "value_cents", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "value_usd_cents", default: 0, null: false
    t.index ["purchase_id"], name: "index_tips_on_purchase_id"
  end

  create_table "top_sellers", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "sales_usd", default: 0, null: false
    t.bigint "sales_count", default: 0, null: false
    t.integer "rank", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["rank"], name: "index_top_sellers_on_rank"
    t.index ["user_id"], name: "index_top_sellers_on_user_id", unique: true
  end

  create_table "tos_agreements", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "user_id"
    t.string "ip"
    t.datetime "created_at", precision: nil
    t.index ["user_id"], name: "index_tos_agreements_on_user_id"
  end

  create_table "transcoded_videos", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "link_id"
    t.string "original_video_key", limit: 1024
    t.string "transcoded_video_key", limit: 2048
    t.string "job_id"
    t.string "state"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.bigint "product_file_id"
    t.integer "flags", default: 0, null: false
    t.datetime "deleted_from_cdn_at", precision: nil
    t.datetime "deleted_at"
    t.datetime "last_accessed_at"
    t.string "streamable_type"
    t.bigint "streamable_id"
    t.index ["deleted_at"], name: "index_transcoded_videos_on_deleted_at"
    t.index ["deleted_from_cdn_at"], name: "index_transcoded_videos_on_deleted_from_cdn_at"
    t.index ["job_id"], name: "index_transcoded_videos_on_job_id"
    t.index ["last_accessed_at"], name: "index_transcoded_videos_on_last_accessed_at"
    t.index ["link_id"], name: "index_transcoded_videos_on_link_id"
    t.index ["original_video_key"], name: "index_transcoded_videos_on_original_video_key", length: 768
    t.index ["product_file_id"], name: "index_transcoded_videos_on_product_file_id"
    t.index ["streamable_type", "streamable_id"], name: "index_transcoded_videos_on_streamable"
    t.index ["transcoded_video_key"], name: "index_transcoded_videos_on_transcoded_video_key", length: 768
  end

  create_table "upsell_purchases", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "upsell_id", null: false
    t.bigint "purchase_id", null: false
    t.bigint "selected_product_id"
    t.bigint "upsell_variant_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["purchase_id"], name: "index_upsell_purchases_on_purchase_id"
    t.index ["selected_product_id"], name: "index_upsell_purchases_on_selected_product_id"
    t.index ["upsell_id"], name: "index_upsell_purchases_on_upsell_id"
    t.index ["upsell_variant_id"], name: "index_upsell_purchases_on_upsell_variant_id"
  end

  create_table "upsell_variants", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "upsell_id", null: false
    t.bigint "selected_variant_id", null: false
    t.bigint "offered_variant_id", null: false
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["offered_variant_id"], name: "index_upsell_variants_on_offered_variant_id"
    t.index ["selected_variant_id"], name: "index_upsell_variants_on_selected_variant_id"
    t.index ["upsell_id"], name: "index_upsell_variants_on_upsell_id"
  end

  create_table "upsells", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "seller_id", null: false
    t.bigint "product_id", null: false
    t.bigint "variant_id"
    t.bigint "offer_code_id"
    t.string "name"
    t.boolean "cross_sell", null: false
    t.string "text"
    t.text "description"
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "universal", default: false, null: false
    t.integer "flags", default: 0, null: false
    t.boolean "paused", default: false, null: false
    t.index ["offer_code_id"], name: "index_upsells_on_offer_code_id"
    t.index ["product_id"], name: "index_upsells_on_offered_product_id"
    t.index ["seller_id"], name: "index_upsells_on_seller_id"
    t.index ["variant_id"], name: "index_upsells_on_offered_variant_id"
  end

  create_table "upsells_selected_products", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "upsell_id", null: false
    t.bigint "selected_product_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["selected_product_id"], name: "index_upsells_selected_products_on_product_id"
    t.index ["upsell_id"], name: "index_upsells_selected_products_on_upsell_id"
  end

  create_table "url_redirects", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "uses", default: 0
    t.datetime "expires_at", precision: nil
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.bigint "purchase_id"
    t.string "token", null: false
    t.bigint "link_id"
    t.integer "flags", default: 0, null: false
    t.bigint "installment_id"
    t.bigint "subscription_id"
    t.bigint "preorder_id"
    t.bigint "imported_customer_id"
    t.datetime "rental_first_viewed_at", precision: nil
    t.index ["imported_customer_id"], name: "index_url_redirects_on_imported_customer_id"
    t.index ["installment_id", "imported_customer_id"], name: "index_url_redirects_on_installment_id_and_imported_customer_id"
    t.index ["installment_id", "purchase_id"], name: "index_url_redirects_on_installment_id_and_purchase_id"
    t.index ["installment_id", "subscription_id"], name: "index_url_redirects_on_installment_id_and_subscription_id"
    t.index ["preorder_id"], name: "index_url_redirects_on_preorder_id"
    t.index ["purchase_id"], name: "index_url_redirects_on_purchase_id"
    t.index ["subscription_id"], name: "index_url_redirects_on_subscription_id"
    t.index ["token"], name: "index_url_redirects_on_token", unique: true
  end

  create_table "user_compliance_info", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "user_id"
    t.string "full_name"
    t.string "street_address"
    t.string "city"
    t.string "state"
    t.string "zip_code"
    t.string "country"
    t.string "telephone_number"
    t.string "vertical"
    t.boolean "is_business"
    t.boolean "has_sold_before"
    t.binary "individual_tax_id"
    t.text "json_data"
    t.integer "flags", default: 0, null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "business_name"
    t.string "business_street_address"
    t.string "business_city"
    t.string "business_state"
    t.string "business_zip_code"
    t.string "business_country"
    t.string "business_type"
    t.binary "business_tax_id"
    t.date "birthday"
    t.datetime "deleted_at", precision: nil
    t.string "dba"
    t.text "verticals"
    t.string "first_name"
    t.string "last_name"
    t.string "stripe_identity_document_id"
    t.index ["user_id"], name: "index_user_compliance_info_on_user_id"
  end

  create_table "user_compliance_info_requests", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.integer "user_id"
    t.string "field_needed"
    t.datetime "due_at", precision: nil
    t.string "state"
    t.datetime "provided_at", precision: nil
    t.text "json_data"
    t.integer "flags", default: 0, null: false
    t.index ["user_id", "state"], name: "index_user_compliance_info_requests_on_user_id_and_state"
  end

  create_table "users", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "email", default: ""
    t.string "encrypted_password", limit: 128, default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at", precision: nil
    t.datetime "remember_created_at", precision: nil
    t.integer "sign_in_count", default: 0
    t.datetime "current_sign_in_at", precision: nil
    t.datetime "last_sign_in_at", precision: nil
    t.string "current_sign_in_ip"
    t.string "last_sign_in_ip"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.string "name"
    t.string "payment_address"
    t.datetime "confirmed_at", precision: nil
    t.string "confirmation_token"
    t.datetime "confirmation_sent_at", precision: nil
    t.string "unconfirmed_email"
    t.string "provider"
    t.string "twitter_user_id"
    t.string "facebook_uid"
    t.datetime "deleted_at", precision: nil
    t.boolean "payment_notification", default: true
    t.string "currency_type", default: "usd"
    t.text "bio", size: :medium
    t.string "twitter_handle"
    t.string "username"
    t.bigint "credit_card_id"
    t.string "profile_picture_url"
    t.string "country"
    t.string "state"
    t.string "city"
    t.string "zip_code"
    t.string "street_address"
    t.string "facebook_access_token", limit: 1024
    t.boolean "verified"
    t.boolean "manage_pages", default: false
    t.datetime "banned_at", precision: nil
    t.boolean "weekly_notification", default: true
    t.string "external_id"
    t.string "account_created_ip"
    t.string "twitter_oauth_token"
    t.string "twitter_oauth_secret"
    t.text "notification_endpoint", size: :medium
    t.string "locale", default: "en"
    t.bigint "flags", default: 1, null: false
    t.string "google_analytics_id"
    t.string "timezone", default: "Pacific Time (US & Canada)", null: false
    t.string "user_risk_state"
    t.string "tos_violation_reason"
    t.string "kindle_email"
    t.text "json_data", size: :medium
    t.string "support_email"
    t.string "google_analytics_domains"
    t.string "recommendation_type", null: false
    t.string "facebook_pixel_id", limit: 191
    t.integer "split_payment_by_cents"
    t.datetime "last_active_sessions_invalidated_at", precision: nil
    t.string "otp_secret_key"
    t.string "facebook_meta_tag"
    t.integer "tier_state", default: 0
    t.string "orientation_priority_tag"
    t.string "notification_content_type", default: "application/x-www-form-urlencoded"
    t.string "google_uid"
    t.integer "purchasing_power_parity_limit"
    t.index ["account_created_ip"], name: "index_users_on_account_created_ip"
    t.index ["confirmation_token"], name: "index_users_on_confirmation_token", length: 191
    t.index ["created_at"], name: "index_users_on_created_at"
    t.index ["current_sign_in_ip"], name: "index_users_on_current_sign_in_ip"
    t.index ["email"], name: "index_users_on_email", length: 191
    t.index ["external_id"], name: "index_users_on_external_id", length: 191
    t.index ["facebook_uid"], name: "index_users_on_facebook_uid", length: 191
    t.index ["google_uid"], name: "index_users_on_google_uid"
    t.index ["last_sign_in_ip"], name: "index_users_on_last_sign_in_ip"
    t.index ["name"], name: "index_users_on_name"
    t.index ["payment_address", "user_risk_state"], name: "index_users_on_payment_address_and_user_risk_state"
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token"
    t.index ["support_email"], name: "index_users_on_support_email"
    t.index ["tos_violation_reason"], name: "index_users_on_tos_violation_reason"
    t.index ["twitter_oauth_token"], name: "index_users_on_twitter_oauth_token"
    t.index ["twitter_user_id"], name: "index_users_on_twitter_user_id", length: 191
    t.index ["unconfirmed_email"], name: "index_users_on_unconfirmed_email", length: 191
    t.index ["user_risk_state"], name: "index_users_on_user_risk_state"
    t.index ["username"], name: "index_users_on_username", length: 191
  end

  create_table "utm_link_driven_sales", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "utm_link_id", null: false
    t.bigint "utm_link_visit_id", null: false
    t.bigint "purchase_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["purchase_id"], name: "index_utm_link_driven_sales_on_purchase_id"
    t.index ["utm_link_id"], name: "index_utm_link_driven_sales_on_utm_link_id"
    t.index ["utm_link_visit_id", "purchase_id"], name: "idx_on_utm_link_visit_id_purchase_id_c31951f65f", unique: true
    t.index ["utm_link_visit_id"], name: "index_utm_link_driven_sales_on_utm_link_visit_id"
  end

  create_table "utm_link_visits", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "utm_link_id", null: false
    t.bigint "user_id"
    t.string "referrer"
    t.string "ip_address", null: false
    t.string "user_agent"
    t.string "browser_guid", null: false
    t.string "country_code"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["browser_guid"], name: "index_utm_link_visits_on_browser_guid"
    t.index ["created_at"], name: "index_utm_link_visits_on_created_at"
    t.index ["user_id"], name: "index_utm_link_visits_on_user_id"
    t.index ["utm_link_id"], name: "index_utm_link_visits_on_utm_link_id"
  end

  create_table "utm_links", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "seller_id", null: false
    t.string "title", null: false
    t.string "target_resource_type", null: false
    t.bigint "target_resource_id"
    t.string "permalink", null: false
    t.string "utm_campaign", limit: 200, null: false
    t.string "utm_medium", limit: 200, null: false
    t.string "utm_source", limit: 200, null: false
    t.string "utm_term", limit: 200
    t.string "utm_content", limit: 200
    t.datetime "first_click_at"
    t.datetime "last_click_at"
    t.integer "total_clicks", default: 0, null: false
    t.integer "unique_clicks", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "deleted_at", precision: nil
    t.datetime "disabled_at", precision: nil
    t.string "ip_address"
    t.string "browser_guid"
    t.index ["deleted_at"], name: "index_utm_links_on_deleted_at"
    t.index ["permalink"], name: "index_utm_links_on_permalink", unique: true
    t.index ["seller_id", "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "target_resource_type", "target_resource_id"], name: "index_utm_links_on_utm_fields_and_target_resource", unique: true, length: { utm_source: 100, utm_medium: 100, utm_campaign: 100, utm_term: 100, utm_content: 100 }
    t.index ["seller_id"], name: "index_utm_links_on_seller_id"
    t.index ["target_resource_type", "target_resource_id"], name: "index_utm_links_on_target_resource_type_and_target_resource_id"
    t.index ["utm_campaign"], name: "index_utm_links_on_utm_campaign"
  end

  create_table "variant_categories", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.integer "link_id"
    t.datetime "deleted_at", precision: nil
    t.string "title"
    t.integer "flags", default: 0, null: false
    t.index ["link_id"], name: "index_variant_categories_on_link_id"
  end

  create_table "versions", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "item_type", limit: 191, null: false
    t.bigint "item_id", null: false
    t.string "event", limit: 191, null: false
    t.string "whodunnit", limit: 191
    t.text "object", size: :long
    t.datetime "created_at"
    t.string "remote_ip", limit: 191
    t.text "request_path"
    t.string "request_uuid", limit: 191
    t.text "object_changes", size: :long
    t.index ["item_type", "item_id"], name: "index_versions_on_item_type_and_item_id"
  end

  create_table "video_files", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.string "url"
    t.string "filetype"
    t.integer "width"
    t.integer "height"
    t.integer "duration"
    t.integer "bitrate"
    t.integer "framerate"
    t.integer "size"
    t.integer "flags", default: 0
    t.datetime "deleted_at"
    t.datetime "deleted_from_cdn_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["record_type", "record_id"], name: "index_video_files_on_record"
    t.index ["user_id"], name: "index_video_files_on_user_id"
  end

  create_table "wishlist_followers", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "wishlist_id", null: false
    t.bigint "follower_user_id", null: false
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["follower_user_id"], name: "index_wishlist_followers_on_follower_user_id"
    t.index ["wishlist_id"], name: "index_wishlist_followers_on_wishlist_id"
  end

  create_table "wishlist_products", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "wishlist_id", null: false
    t.bigint "product_id", null: false
    t.bigint "variant_id"
    t.string "recurrence"
    t.integer "quantity", null: false
    t.boolean "rent", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "deleted_at"
    t.index ["product_id"], name: "index_wishlist_products_on_product_id"
    t.index ["variant_id"], name: "index_wishlist_products_on_variant_id"
    t.index ["wishlist_id"], name: "index_wishlist_products_on_wishlist_id"
  end

  create_table "wishlists", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "name", null: false
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "followers_last_contacted_at"
    t.text "description"
    t.integer "flags", default: 0, null: false
    t.boolean "recommendable", default: false, null: false
    t.integer "follower_count", default: 0, null: false
    t.integer "recent_follower_count", default: 0, null: false
    t.index ["recommendable", "recent_follower_count"], name: "index_wishlists_on_recommendable_and_recent_follower_count"
    t.index ["user_id"], name: "index_wishlists_on_user_id"
  end

  create_table "workflows", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.string "name", limit: 1024
    t.integer "seller_id"
    t.integer "link_id"
    t.string "workflow_type"
    t.datetime "published_at", precision: nil
    t.datetime "deleted_at", precision: nil
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.integer "base_variant_id"
    t.text "json_data"
    t.datetime "first_published_at", precision: nil
    t.bigint "flags", default: 0, null: false
    t.index ["base_variant_id"], name: "index_workflows_on_base_variant_id"
    t.index ["link_id"], name: "index_workflows_on_link_id"
    t.index ["seller_id"], name: "index_workflows_on_seller_id"
    t.index ["workflow_type", "published_at"], name: "index_workflows_on_workflow_type_and_published_at"
  end

  create_table "yearly_stats", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.json "analytics_data", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_yearly_stats_on_user_id", unique: true
  end

  create_table "zip_tax_rates", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
    t.decimal "combined_rate", precision: 8, scale: 7
    t.decimal "county_rate", precision: 8, scale: 7
    t.decimal "city_rate", precision: 8, scale: 7
    t.string "state"
    t.decimal "state_rate", precision: 8, scale: 7
    t.string "tax_region_code"
    t.string "tax_region_name"
    t.string "zip_code"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.decimal "special_rate", precision: 8, scale: 7
    t.integer "flags", default: 0, null: false
    t.string "country", null: false
    t.integer "user_id"
    t.datetime "deleted_at", precision: nil
    t.text "json_data"
    t.index ["user_id"], name: "index_zip_tax_rates_on_user_id"
    t.index ["zip_code"], name: "index_zip_tax_rates_on_zip_code"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
end
