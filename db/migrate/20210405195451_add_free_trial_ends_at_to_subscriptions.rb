# frozen_string_literal: true

class AddFreeTrialEndsAtToSubscriptions < ActiveRecord::Migration[6.1]
  def change
    add_column :subscriptions, :free_trial_ends_at, :datetime
  end
end
