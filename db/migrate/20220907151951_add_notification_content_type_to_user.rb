# frozen_string_literal: true

class AddNotificationContentTypeToUser < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :notification_content_type, :string, default: "application/x-www-form-urlencoded"
  end
end
