# frozen_string_literal: true

class CreateAssignments < ActiveRecord::Migration
  def change
    create_table :assignments do |t|
      t.integer :ab_test_id
      t.integer :test_path_id
      t.string :browser_guid
      t.timestamps
    end

    add_index "assignments", ["browser_guid", "ab_test_id"], name: "index_assignments_on_browser_guid_and_ab_test_id", unique: true
    add_index "assignments", ["test_path_id", "browser_guid"], name: "index_assignments_on_test_path_id_and_browser_guid"
  end
end
