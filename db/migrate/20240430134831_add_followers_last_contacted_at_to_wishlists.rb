# frozen_string_literal: true

class AddFollowersLastContactedAtToWishlists < ActiveRecord::Migration[7.1]
  def change
    add_column :wishlists, :followers_last_contacted_at, :datetime
  end
end
