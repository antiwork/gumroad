# frozen_string_literal: true

class AddSubscriptionDurationToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :subscription_duration, :integer
  end
end
