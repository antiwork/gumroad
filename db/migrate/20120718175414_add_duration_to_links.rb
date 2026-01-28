# frozen_string_literal: true

class AddDurationToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :duration, :integer
  end
end
