# frozen_string_literal: true

class AddBackAdminActionCallInfos < ActiveRecord::Migration[7.1]
  def change
    create_table :admin_action_call_infos, charset: "utf8mb4", collation: "utf8mb4_unicode_ci" do |t|
      t.string :controller_name, null: false
      t.string :action_name, null: false
      t.integer :call_count, default: 0, null: false

      t.timestamps
      t.index [:controller_name, :action_name], name: "index_admin_action_call_infos_on_controller_name_and_action_name", unique: true
    end
  end
end
