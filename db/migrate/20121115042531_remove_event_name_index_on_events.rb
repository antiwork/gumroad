# frozen_string_literal: true

class RemoveEventNameIndexOnEvents < ActiveRecord::Migration[4.2]
  def up
    remove_index "events", "event_type"
  end

  def down
    add_index "events", "event_type"
  end
end
