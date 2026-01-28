# frozen_string_literal: true

class AddUserRequestedCancellationAtToSubscription < ActiveRecord::Migration[4.2]
  def change
    add_column :subscriptions, :user_requested_cancellation_at, :datetime
  end
end
