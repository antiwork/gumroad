# frozen_string_literal: true

class AddIndexToLinkIdOnSubscriptions < ActiveRecord::Migration[4.2]
  def change
    add_index :subscriptions, :link_id
  end
end
