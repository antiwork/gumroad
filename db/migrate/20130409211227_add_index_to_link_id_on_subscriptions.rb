# frozen_string_literal: true

class AddIndexToLinkIdOnSubscriptions < ActiveRecord::Migration
  def change
    add_index :subscriptions, :link_id
  end
end
