# frozen_string_literal: true

class AddBanFlagToUsers < ActiveRecord::Migration
  def change
    add_column :users, :ban_flag, :boolean
  end
end
