# frozen_string_literal: true

class AddNotificationEndpointToUsers < ActiveRecord::Migration
  def change
    add_column :users, :notification_endpoint, :text
  end
end
