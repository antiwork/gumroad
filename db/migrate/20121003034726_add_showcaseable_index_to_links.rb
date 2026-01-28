# frozen_string_literal: true

class AddShowcaseableIndexToLinks < ActiveRecord::Migration[4.2]
  def change
    add_index :links, :showcaseable
  end
end
