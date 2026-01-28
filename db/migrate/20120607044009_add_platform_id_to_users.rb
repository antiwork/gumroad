# frozen_string_literal: true

class AddPlatformIdToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :platform_id, :integer
  end
end
