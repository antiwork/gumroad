# frozen_string_literal: true

class AddWeeklyNotificationToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column(:users, :weekly_notification, :boolean, { default: true })
  end
end
