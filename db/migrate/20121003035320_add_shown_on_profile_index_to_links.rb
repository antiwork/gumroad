# frozen_string_literal: true

class AddShownOnProfileIndexToLinks < ActiveRecord::Migration
  def change
    add_index :links, :shown_on_profile
  end
end
