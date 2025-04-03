# frozen_string_literal: true

class AddShowcaseableIndexToLinks < ActiveRecord::Migration
  def change
    add_index :links, :showcaseable
  end
end
