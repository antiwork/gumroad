# frozen_string_literal: true

class RemoveTwitterHandleFromUsers < ActiveRecord::Migration[7.1]
  def change
    remove_column :users, :twitter_handle, :string
  end
end
