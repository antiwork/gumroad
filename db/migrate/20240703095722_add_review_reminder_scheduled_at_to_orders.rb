# frozen_string_literal: true

class AddReviewReminderScheduledAtToOrders < ActiveRecord::Migration[7.1]
  def change
    add_column :orders, :review_reminder_scheduled_at, :datetime
  end
end
