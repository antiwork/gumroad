# frozen_string_literal: true

class AddReassignmentLockedAtToPurchases < ActiveRecord::Migration[7.1]
  def change
    add_column :purchases, :reassignment_locked_at, :datetime
  end
end
