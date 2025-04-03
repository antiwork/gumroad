# frozen_string_literal: true

class AddSubscriptionDurationToLinks < ActiveRecord::Migration
  def change
    add_column :links, :subscription_duration, :integer
  end
end
