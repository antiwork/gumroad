# frozen_string_literal: true

class RemoveUnusedParentsChidren < ActiveRecord::Migration[6.0]
  def up
    drop_table :parents_children
  end

  def down
    create_table "parents_children", id: false, options: "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci", force: :cascade do |t|
      t.integer "parent_id"
      t.integer "child_id"
      t.datetime "created_at"
      t.datetime "updated_at"
      t.index ["child_id"], name: "index_parents_children_on_child_id"
      t.index ["parent_id"], name: "index_parents_children_on_parent_id"
    end
  end
end
