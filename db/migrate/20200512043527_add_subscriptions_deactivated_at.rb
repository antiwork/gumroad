# frozen_string_literal: true

class AddSubscriptionsDeactivatedAt < ActiveRecord::Migration
  def up
    add_column :subscriptions, :deactivated_at, :datetime
    add_index :subscriptions, :deactivated_at
    add_index :subscriptions, :ended_at
  end

  def down
    remove_column :subscriptions, :deactivated_at
    remove_index :subscriptions, :ended_at
  end
end
