# frozen_string_literal: true

class AddTierStateToUser < ActiveRecord::Migration[6.1]
  def change
    add_column :users, :tier_state, :integer, default: 0
  end
end
