# frozen_string_literal: true

class AddColumnConfirmedAtToFollowers < ActiveRecord::Migration
  def change
    add_column :followers, :confirmed_at, :datetime

    reversible do |direction|
      direction.up do
        Follower.reset_column_information
        Follower.alive.update_all(confirmed_at: Time.current)
      end
    end
  end
end
