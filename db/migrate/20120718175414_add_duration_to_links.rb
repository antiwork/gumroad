# frozen_string_literal: true

class AddDurationToLinks < ActiveRecord::Migration
  def change
    add_column :links, :duration, :integer
  end
end
