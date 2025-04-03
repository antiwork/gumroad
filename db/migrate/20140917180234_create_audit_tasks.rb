# frozen_string_literal: true

class CreateAuditTasks < ActiveRecord::Migration
  def change
    create_table :audit_tasks do |t|
      t.string :name
      t.references :owner
      t.date :due_date
      t.string :status
      t.integer :recurrence_days

      t.timestamps
    end
    add_index :audit_tasks, :owner_id
    add_index :audit_tasks, :due_date
    add_index :audit_tasks, :status
  end
end
