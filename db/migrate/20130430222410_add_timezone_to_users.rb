# frozen_string_literal: true

class AddTimezoneToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :timezone, :string, default: "Pacific Time (US & Canada)", null: false
  end
end
