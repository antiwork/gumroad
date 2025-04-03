# frozen_string_literal: true

class CreateEventTestPathsAssignmentsTable < ActiveRecord::Migration
  def change
    create_table :event_test_path_assignments do |t|
      t.integer :event_id
      t.string :event_name
      t.string :active_test_paths
      t.timestamps
    end

    add_index "event_test_path_assignments", ["event_id"], name: "index_event_test_path_assignments_on_event_id"
    add_index "event_test_path_assignments", ["active_test_paths", "event_name"], name: "index_event_assignments_on_active_test_paths_and_event_name"
  end
end
