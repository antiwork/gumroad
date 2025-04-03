# frozen_string_literal: true

class CreateTestPathsTable < ActiveRecord::Migration
  def change
    create_table :test_paths do |t|
      t.string :alternative_name
      t.integer :ab_test_id
      t.timestamps
    end

    add_index "test_paths", ["ab_test_id", "alternative_name"], name: "index_assignments_on_ab_test_id_and_alternative_name"
    add_index "test_paths", "alternative_name", name: "index_assignments_on_alternative_name"
  end
end
