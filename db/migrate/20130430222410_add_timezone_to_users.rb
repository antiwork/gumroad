# frozen_string_literal: true

class AddTimezoneToUsers < ActiveRecord::Migration
  def change
    add_column :users, :timezone, :string, default: "Pacific Time (US & Canada)", null: false
  end
end
