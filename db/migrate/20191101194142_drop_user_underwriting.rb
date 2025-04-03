# frozen_string_literal: true

class DropUserUnderwriting < ActiveRecord::Migration
  def up
    drop_table :user_underwriting
  end

  def down
    create_table "user_underwriting" do |t|
      t.integer  "user_id",                    limit: 4
      t.integer  "user_compliance_info_id",    limit: 4
      t.integer  "bank_account_id",            limit: 4
      t.integer  "queued_by_admin_user_id",    limit: 4
      t.integer  "approved_by_admin_user_id",  limit: 4
      t.string   "from_relationship",          limit: 255
      t.string   "to_relationship",            limit: 255
      t.string   "underwriting_state",         limit: 255
      t.string   "submission_group_id",        limit: 255
      t.datetime "created_at"
      t.datetime "updated_at"
      t.datetime "approved_at"
      t.datetime "submitted_at"
      t.datetime "acknowledged_at"
      t.datetime "negatively_acknowledged_at"
      t.datetime "merchant_accepted_at"
      t.datetime "merchant_rejected_at"
    end

    add_index "user_underwriting", ["user_id"], name: "index_user_underwriting_on_user_id", using: :btree
  end
end
