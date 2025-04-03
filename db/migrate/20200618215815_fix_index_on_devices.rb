# frozen_string_literal: true

class FixIndexOnDevices < ActiveRecord::Migration
  def up
    remove_index :devices, column: :token
    add_index :devices, [:token, :device_type], unique: true
  end

  def down
    remove_index :devices,  [:token, :device_type]
    add_index :devices, :token, unique: true
  end
end
