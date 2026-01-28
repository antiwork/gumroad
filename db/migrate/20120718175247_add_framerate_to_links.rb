# frozen_string_literal: true

class AddFramerateToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :framerate, :integer
  end
end
