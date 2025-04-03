# frozen_string_literal: true

class DropAdminActionCallInfosTable < ActiveRecord::Migration[7.1]
  def up
    drop_table :admin_action_call_infos
  end

  def down
    create_table :admin_action_call_infos do |t|
      t.string :controller_name, null: false
      t.string :action_name, null: false
      t.integer :call_count, default: 0, null: false

      t.timestamps
    end

    add_index :admin_action_call_infos, [:controller_name, :action_name], unique: true
  end
end
