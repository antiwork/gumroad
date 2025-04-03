# frozen_string_literal: true

class AddAutobanFlagToUsers < ActiveRecord::Migration
  def change
    add_column :users, :autoban_flag, :boolean
  end
end
