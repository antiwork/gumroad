# frozen_string_literal: true

class AddBitrateToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :bitrate, :integer
  end
end
