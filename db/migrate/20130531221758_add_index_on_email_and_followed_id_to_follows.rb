# frozen_string_literal: true

class AddIndexOnEmailAndFollowedIdToFollows < ActiveRecord::Migration
  def change
    add_index :follows, [:email, :followed_id]
  end
end
