# frozen_string_literal: true

class RemoveUnusedTables < ActiveRecord::Migration
  def up
    drop_table :ab_tests
    drop_table :api_sessions
    drop_table :assignments
    drop_table :audit_tasks
    drop_table :blocked_browser_guids
    drop_table :daily_metrics
    drop_table :purchase_codes
    drop_table :sxsw_meetings
    drop_table :test_paths
    drop_table :twitter_merchants
    drop_table :twitter_orders
    drop_table :visits
  end

  def down
    create_table "ab_tests", force: :cascade do |t|
      t.string   "name",       limit: 191
      t.string   "page_name",  limit: 191
      t.boolean  "is_active",              default: false
      t.datetime "deleted_at"
      t.datetime "created_at",                             null: false
      t.datetime "updated_at",                             null: false
    end

    add_index "ab_tests", ["name", "page_name"], name: "index_ab_tests_on_name_and_page_name", using: :btree
    add_index "ab_tests", ["page_name"], name: "index_ab_tests_on_page_name", using: :btree

    ###

    create_table "api_sessions", force: :cascade do |t|
      t.integer  "user_id",    limit: 4
      t.string   "token",      limit: 191
      t.datetime "created_at"
      t.datetime "updated_at"
      t.datetime "deleted_at"
    end

    add_index "api_sessions", ["token"], name: "index_api_sessions_on_token", using: :btree
    add_index "api_sessions", ["user_id"], name: "index_api_sessions_on_user_id", using: :btree

    ###

    create_table "assignments", force: :cascade do |t|
      t.integer  "ab_test_id",   limit: 4
      t.integer  "test_path_id", limit: 4
      t.string   "browser_guid", limit: 191
      t.datetime "created_at",               null: false
      t.datetime "updated_at",               null: false
    end

    add_index "assignments", ["browser_guid", "ab_test_id"], name: "index_assignments_on_browser_guid_and_ab_test_id", unique: true, using: :btree
    add_index "assignments", ["test_path_id", "browser_guid"], name: "index_assignments_on_test_path_id_and_browser_guid", using: :btree

    ###

    create_table "audit_tasks", force: :cascade do |t|
      t.string   "name",            limit: 191
      t.integer  "owner_id",        limit: 4
      t.date     "due_date"
      t.string   "status",          limit: 191
      t.integer  "recurrence_days", limit: 4
      t.datetime "created_at",                  null: false
      t.datetime "updated_at",                  null: false
    end

    add_index "audit_tasks", ["due_date"], name: "index_audit_tasks_on_due_date", using: :btree
    add_index "audit_tasks", ["owner_id"], name: "index_audit_tasks_on_owner_id", using: :btree
    add_index "audit_tasks", ["status"], name: "index_audit_tasks_on_status", using: :btree

    ###

    create_table "blocked_browser_guids", force: :cascade do |t|
      t.string   "browser_guid", limit: 191
      t.datetime "blocked_at"
      t.datetime "created_at",               null: false
      t.datetime "updated_at",               null: false
    end

    add_index "blocked_browser_guids", ["browser_guid"], name: "index_blocked_browser_guids_on_browser_guid", using: :btree

    ###

    create_table "daily_metrics", force: :cascade do |t|
      t.string   "event_name",  limit: 191
      t.date     "events_date"
      t.integer  "event_count", limit: 4
      t.integer  "user_count",  limit: 4
      t.datetime "created_at",                              null: false
      t.datetime "updated_at",                              null: false
      t.string   "source_type", limit: 191, default: "all"
    end

    add_index "daily_metrics", ["event_name", "events_date", "source_type"], name: "index_daily_metrics_on_event_name_events_date_and_source_type", unique: true, using: :btree

    ###

    create_table "purchase_codes", force: :cascade do |t|
      t.string   "token",           limit: 191
      t.datetime "used_at"
      t.datetime "expires_at"
      t.integer  "url_redirect_id", limit: 4
      t.datetime "created_at",                  null: false
      t.datetime "updated_at",                  null: false
      t.integer  "subscription_id", limit: 4
      t.integer  "purchase_id",     limit: 4
    end

    add_index "purchase_codes", ["purchase_id"], name: "index_purchase_codes_on_purchase_id", using: :btree
    add_index "purchase_codes", ["subscription_id"], name: "index_purchase_codes_on_subscription_id", using: :btree
    add_index "purchase_codes", ["token"], name: "index_purchase_codes_on_token", using: :btree
    add_index "purchase_codes", ["url_redirect_id"], name: "index_purchase_codes_on_url_redirect_id", using: :btree

    ###

    create_table "sxsw_meetings", force: :cascade do |t|
      t.string   "email",       limit: 191
      t.string   "name",        limit: 191
      t.integer  "time_slot",   limit: 4
      t.boolean  "confirmed"
      t.text     "message",     limit: 65535
      t.string   "guest_name",  limit: 191
      t.string   "guest_email", limit: 191
      t.datetime "created_at",                null: false
      t.datetime "updated_at",                null: false
    end

    ###

    create_table "test_paths", force: :cascade do |t|
      t.string   "alternative_name", limit: 191
      t.integer  "ab_test_id",       limit: 4
      t.datetime "created_at",                   null: false
      t.datetime "updated_at",                   null: false
    end

    add_index "test_paths", ["ab_test_id", "alternative_name"], name: "index_assignments_on_ab_test_id_and_alternative_name", using: :btree
    add_index "test_paths", ["alternative_name"], name: "index_assignments_on_alternative_name", using: :btree

    ###

    create_table "twitter_merchants", force: :cascade do |t|
      t.integer  "user_id",                      limit: 4
      t.string   "email",                        limit: 191
      t.string   "name",                         limit: 191
      t.string   "support_email",                limit: 191
      t.string   "domains",                      limit: 191
      t.string   "twitter_assigned_merchant_id", limit: 191
      t.integer  "flags",                        limit: 4,   default: 0, null: false
      t.datetime "created_at",                                           null: false
      t.datetime "updated_at",                                           null: false
    end

    add_index "twitter_merchants", ["twitter_assigned_merchant_id"], name: "index_twitter_merchants_on_twitter_assigned_merchant_id", using: :btree
    add_index "twitter_merchants", ["user_id"], name: "index_twitter_merchants_on_user_id", using: :btree

    ###

    create_table "twitter_orders", force: :cascade do |t|
      t.integer  "purchase_id",                  limit: 4
      t.string   "twitter_order_id",             limit: 191
      t.integer  "order_timestamp",              limit: 8
      t.string   "stripe_transaction_id",        limit: 191
      t.integer  "charge_amount_micro_currency", limit: 4
      t.string   "charge_state",                 limit: 191
      t.integer  "tax_micro_currency",           limit: 4
      t.string   "sku_id",                       limit: 191
      t.string   "tax_category",                 limit: 191
      t.integer  "sku_price_micro_currency",     limit: 4
      t.integer  "quantity",                     limit: 4
      t.string   "twitter_handle",               limit: 191
      t.string   "twitter_user_id",              limit: 191
      t.string   "email",                        limit: 191
      t.string   "ip_address",                   limit: 191
      t.string   "device_id",                    limit: 191
      t.string   "full_name",                    limit: 191
      t.string   "street_address_1",             limit: 191
      t.string   "street_address_2",             limit: 191
      t.string   "city",                         limit: 191
      t.string   "zip_code",                     limit: 191
      t.string   "state",                        limit: 191
      t.string   "country",                      limit: 191
      t.integer  "tweet_view_timestamp",         limit: 8
      t.string   "tweet_id",                     limit: 191
      t.integer  "flags",                        limit: 4,     default: 0, null: false
      t.text     "json_data",                    limit: 65535
      t.datetime "created_at",                                             null: false
      t.datetime "updated_at",                                             null: false
      t.string   "user_agent",                   limit: 191
    end

    add_index "twitter_orders", ["email"], name: "index_twitter_orders_on_email", using: :btree
    add_index "twitter_orders", ["purchase_id"], name: "index_twitter_orders_on_purchase_id", using: :btree
    add_index "twitter_orders", ["sku_id"], name: "index_twitter_orders_on_sku_id", using: :btree
    add_index "twitter_orders", ["tweet_id"], name: "index_twitter_orders_on_tweet_id", using: :btree
    add_index "twitter_orders", ["twitter_order_id"], name: "index_twitter_orders_on_twitter_order_id", using: :btree

    ###

    create_table "visits", force: :cascade do |t|
      t.string   "ip_address",          limit: 191
      t.datetime "created_at"
      t.string   "entry_point",         limit: 191
      t.datetime "updated_at"
      t.string   "fingerprint",         limit: 191
      t.integer  "user_id",             limit: 4
      t.boolean  "is_modal"
      t.string   "browser_fingerprint", limit: 191
      t.string   "browser_guid",        limit: 191
    end

    add_index "visits", ["browser_fingerprint"], name: "index_visits_on_browser_fingerprint", using: :btree
    add_index "visits", ["browser_guid"], name: "index_visits_on_browser_guid", using: :btree
    add_index "visits", ["created_at"], name: "index_visits_on_created_at", using: :btree
    add_index "visits", ["entry_point"], name: "index_visits_on_entry_point", using: :btree
    add_index "visits", ["fingerprint"], name: "index_visits_on_fingerprint", using: :btree
    add_index "visits", ["ip_address"], name: "index_visits_on_ip_address", using: :btree
  end
end
