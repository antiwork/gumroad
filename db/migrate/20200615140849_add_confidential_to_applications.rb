# frozen_string_literal: true

class AddConfidentialToApplications < ActiveRecord::Migration
  def up
    # Default generated is true. We set this to false for backwards compat
    # https://github.com/doorkeeper-gem/doorkeeper/wiki/Migration-from-old-versions#database-changes-1
    add_column :oauth_applications, :confidential, :boolean, null: false
    change_column_default :oauth_applications, :confidential, false
  end

  def down
    remove_column :oauth_applications, :confidential
  end
end
