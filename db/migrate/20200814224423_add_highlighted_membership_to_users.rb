# frozen_string_literal: true

class AddHighlightedMembershipToUsers < ActiveRecord::Migration[5.0]
  def change
    add_reference :users, :highlighted_membership
  end
end
