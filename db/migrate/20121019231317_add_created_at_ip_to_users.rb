# frozen_string_literal: true

class AddCreatedAtIpToUsers < ActiveRecord::Migration
  def up
    add_column :users, :account_created_ip, :string
  end

  def down
    remove_column :users, :account_created_ip, :string
  end
end
