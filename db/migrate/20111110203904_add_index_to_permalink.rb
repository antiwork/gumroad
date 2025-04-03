# frozen_string_literal: true

class AddIndexToPermalink < ActiveRecord::Migration
  def up
    add_index :links, :unique_permalink
  end

  def down
    remove_index :links, :unique_permalink
  end
end
