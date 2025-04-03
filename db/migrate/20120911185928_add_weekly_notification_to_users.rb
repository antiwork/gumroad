# frozen_string_literal: true

class AddWeeklyNotificationToUsers < ActiveRecord::Migration
  def change
    add_column(:users, :weekly_notification, :boolean, { default: true })
  end
end
