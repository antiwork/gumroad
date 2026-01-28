# frozen_string_literal: true

class AddClicksToDiscoverSearches < ActiveRecord::Migration[4.2]
  def change
    add_reference :discover_searches, :clicked_resource, polymorphic: true
  end
end
