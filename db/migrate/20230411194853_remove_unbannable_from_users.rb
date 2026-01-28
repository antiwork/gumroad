# frozen_string_literal: true

class RemoveUnbannableFromUsers < ActiveRecord::Migration[4.2]
  def change
    remove_column :users, :unbannable, :boolean, default: false
  end
end
