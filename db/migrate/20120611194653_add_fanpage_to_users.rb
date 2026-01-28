# frozen_string_literal: true

class AddFanpageToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :fanpage, :string
  end
end
