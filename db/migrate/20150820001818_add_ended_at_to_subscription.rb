# frozen_string_literal: true

class AddEndedAtToSubscription < ActiveRecord::Migration[4.2]
  def change
    add_column :subscriptions, :ended_at, :datetime
  end
end
