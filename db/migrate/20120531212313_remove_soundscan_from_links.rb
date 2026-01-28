# frozen_string_literal: true

class RemoveSoundscanFromLinks < ActiveRecord::Migration[4.2]
  def change
    remove_column :links, :soundscan
  end
end
