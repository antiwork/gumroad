# frozen_string_literal: true

class AddPlatformCutToUsers < ActiveRecord::Migration
  def change
    add_column :users, :platform_cut, :float
  end
end
