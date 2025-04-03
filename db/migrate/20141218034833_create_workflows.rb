# frozen_string_literal: true

class CreateWorkflows < ActiveRecord::Migration
  def change
    create_table :workflows do |t|
      t.string :name
      t.integer :seller_id
      t.integer :link_id
      t.string :workflow_type
      t.datetime :published_at
      t.datetime :deleted_at
      t.timestamps
    end

    add_index :workflows, [:link_id]
    add_index :workflows, [:seller_id]
  end
end
