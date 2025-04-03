# frozen_string_literal: true

class AddHumanizedNameAndFlagToTags < ActiveRecord::Migration
  def change
    add_column(:tags, :humanized_name, :string, length: 100)
    add_column(:tags, :flagged_at, :datetime, default: nil)
  end
end
