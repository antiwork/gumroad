# frozen_string_literal: true

class AddHighlightedMembershipToUsers < ActiveRecord::Migration[4.2]
  def change
    add_reference :users, :highlighted_membership
  end
end
