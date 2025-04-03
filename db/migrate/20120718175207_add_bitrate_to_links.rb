# frozen_string_literal: true

class AddBitrateToLinks < ActiveRecord::Migration
  def change
    add_column :links, :bitrate, :integer
  end
end
