# frozen_string_literal: true

class AddIndexToPermalink < ActiveRecord::Migration[4.2]
  def up
    add_index :links, :unique_permalink
  end

  def down
    remove_index :links, :unique_permalink
  end
end
