# frozen_string_literal: true

class AddAutobanFlagToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :autoban_flag, :boolean
  end
end
