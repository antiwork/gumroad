# frozen_string_literal: true

class AddNotificationEndpointToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :notification_endpoint, :text
  end
end
