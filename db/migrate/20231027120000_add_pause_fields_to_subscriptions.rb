# frozen_string_literal: true

# TODO: Replace 6.1 with the actual Rails version being used if different.
# The migration version might need adjustment based on the project's Rails version.
# For example, if using Rails 7.0, it would be ActiveRecord::Migration[7.0].
# Assuming 6.1 for now as it's a common version.
class AddPauseFieldsToSubscriptions < ActiveRecord::Migration[6.1]
  def change
    add_column :subscriptions, :paused_at, :datetime, null: true
    add_column :subscriptions, :resumed_at, :datetime, null: true
    add_column :subscriptions, :next_charge_at, :datetime, null: true
  end
end
