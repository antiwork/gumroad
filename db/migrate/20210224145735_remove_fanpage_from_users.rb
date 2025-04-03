# frozen_string_literal: true

class RemoveFanpageFromUsers < ActiveRecord::Migration[6.1]
  def change
    remove_column :users, :fanpage, :string
  end
end
