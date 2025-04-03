# frozen_string_literal: true

class CreateParentsChildren < ActiveRecord::Migration
  def up
    create_table :parents_children, id: false do |t|
      t.references :parent
      t.references :child
      t.timestamps
    end
    add_index :parents_children, :parent_id
    add_index :parents_children, :child_id
  end

  def down
    drop_table :parents_children
  end
end
