# frozen_string_literal: true

class AddHumanizedNameAndFlagToTags < ActiveRecord::Migration[4.2]
  def change
    add_column(:tags, :humanized_name, :string, length: 100)
    add_column(:tags, :flagged_at, :datetime, default: nil)
  end
end
