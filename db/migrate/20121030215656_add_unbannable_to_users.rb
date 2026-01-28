# frozen_string_literal: true

class AddUnbannableToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :unbannable, :boolean, default: false
  end
end
