# frozen_string_literal: true

class AddUserIdAsIndexOnLinksTable < ActiveRecord::Migration[4.2]
  def up
    add_index :links, :user_id
  end

  def down
    remove_index :links, :user_id
  end
end
