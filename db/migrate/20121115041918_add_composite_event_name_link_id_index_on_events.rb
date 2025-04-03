# frozen_string_literal: true

class AddCompositeEventNameLinkIdIndexOnEvents < ActiveRecord::Migration
  def up
    add_index "events", ["event_name", "link_id"]
  end

  def down
    remove_index "events", ["event_name", "link_id"]
  end
end
