# frozen_string_literal: true

class RemoveFollowersCancelledAt < ActiveRecord::Migration[6.1]
  def up
    remove_column :followers, :cancelled_at
  end

  def down
    add_column :followers, :cancelled_at, :datetime
  end
end
