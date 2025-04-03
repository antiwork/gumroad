# frozen_string_literal: true

class AddFanpageToUsers < ActiveRecord::Migration
  def change
    add_column :users, :fanpage, :string
  end
end
