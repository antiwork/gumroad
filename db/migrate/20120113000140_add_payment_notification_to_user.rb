# frozen_string_literal: true

class AddPaymentNotificationToUser < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :payment_notification, :boolean, default: true
  end
end
