# frozen_string_literal: true

class RemoveDynamicProductSwitchesTables < ActiveRecord::Migration[6.1]
  def up
    drop_table :dynamic_product_page_switches
    drop_table :dynamic_product_page_switch_assignments
  end

  def down
    create_table "dynamic_product_page_switches", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
      t.string "name"
      t.integer "default_switch_value"
      t.integer "flags", default: 0, null: false
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
    end

    create_table "dynamic_product_page_switch_assignments", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
      t.integer "link_id"
      t.integer "dynamic_product_page_switch_id"
      t.integer "switch_value"
      t.datetime "deleted_at"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
    end

    add_index "dynamic_product_page_switch_assignments", ["link_id", "dynamic_product_page_switch_id"], name: "index_dynamic_product_page_assignments_on_link_id_and_switch_id"
  end
end
