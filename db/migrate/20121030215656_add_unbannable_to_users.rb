# frozen_string_literal: true

class AddUnbannableToUsers < ActiveRecord::Migration
  def change
    add_column :users, :unbannable, :boolean, default: false
  end
end
