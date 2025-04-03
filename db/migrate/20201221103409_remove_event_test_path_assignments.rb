# frozen_string_literal: true

class RemoveEventTestPathAssignments < ActiveRecord::Migration[6.0]
  def up
    drop_table :event_test_path_assignments
  end

  def down
    create_table "event_test_path_assignments", id: :integer, options: "ENGINE=InnoDB DEFAULT CHARSET=latin1", force: :cascade do |t|
      t.integer "event_id"
      t.string "event_name", limit: 255
      t.string "active_test_paths", limit: 255
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["active_test_paths", "event_name"], name: "index_event_assignments_on_active_test_paths_and_event_name"
      t.index ["event_id"], name: "index_event_test_path_assignments_on_event_id"
    end
  end
end
