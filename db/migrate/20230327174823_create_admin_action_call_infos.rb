# frozen_string_literal: true

class CreateAdminActionCallInfos < ActiveRecord::Migration[7.0]
  def change
    create_table :admin_action_call_infos do |t|
      t.string :controller_name, null: false
      t.string :action_name, null: false
      t.integer :call_count, default: 0, null: false

      t.timestamps
      t.index [:controller_name, :action_name], unique: true
    end
  end
end
