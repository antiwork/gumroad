# frozen_string_literal: true

class RemoveUnbannableFromUsers < ActiveRecord::Migration[7.0]
  def change
    remove_column :users, :unbannable, :boolean, default: false
  end
end
