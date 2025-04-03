# frozen_string_literal: true

class CreateAbTestsTable < ActiveRecord::Migration
  def change
    create_table :ab_tests do |t|
      t.string :name
      t.string :page_name
      t.boolean :is_active, default: false
      t.datetime "deleted_at"
      t.timestamps
    end

    add_index "ab_tests", ["name", "page_name"], name: "index_ab_tests_on_name_and_page_name"
    add_index "ab_tests", "page_name", name: "index_ab_tests_on_page_name"
  end
end
