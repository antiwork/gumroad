# frozen_string_literal: true

class RemoveFbTimezoneAndLocaleFromUsers < ActiveRecord::Migration
  def up
    remove_column :users, :facebook_timezone
    remove_column :users, :facebook_locale
  end

  def down
    add_column :users, :facebook_timezone, :string
    add_column :users, :facebook_locale, :string
  end
end
