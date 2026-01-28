# frozen_string_literal: true

class AddCompositeEventNameLinkIdIndexOnEvents < ActiveRecord::Migration[4.2]
  def up
    add_index "events", ["event_name", "link_id"]
  end

  def down
    remove_index "events", ["event_name", "link_id"]
  end
end
