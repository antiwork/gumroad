# frozen_string_literal: true

class AddPlatformIdToUsers < ActiveRecord::Migration
  def change
    add_column :users, :platform_id, :integer
  end
end
