# frozen_string_literal: true

class AddIndexOnEmailAndFollowedIdToFollows < ActiveRecord::Migration[4.2]
  def change
    add_index :follows, [:email, :followed_id]
  end
end
