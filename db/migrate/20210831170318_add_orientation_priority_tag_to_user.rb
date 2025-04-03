# frozen_string_literal: true

class AddOrientationPriorityTagToUser < ActiveRecord::Migration[6.1]
  def change
    add_column :users, :orientation_priority_tag, :string
  end
end
