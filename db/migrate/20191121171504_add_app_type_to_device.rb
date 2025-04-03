# frozen_string_literal: true

class AddAppTypeToDevice < ActiveRecord::Migration
  def up
    add_column :devices, :app_type, :string, null: false, limit: 255
    change_column_default :devices, :app_type, "consumer"
    add_index :devices, [:app_type, :user_id]
  end

  def down
    remove_column :devices, :app_type
  end
end
