# frozen_string_literal: true

class RemoveFollowersCancelledAt < ActiveRecord::Migration[4.2]
  def up
    remove_column :followers, :cancelled_at
  end

  def down
    add_column :followers, :cancelled_at, :datetime
  end
end
