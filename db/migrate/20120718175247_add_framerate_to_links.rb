# frozen_string_literal: true

class AddFramerateToLinks < ActiveRecord::Migration
  def change
    add_column :links, :framerate, :integer
  end
end
