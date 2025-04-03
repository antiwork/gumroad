# frozen_string_literal: true

class RemoveSoundscanFromLinks < ActiveRecord::Migration
  def change
    remove_column :links, :soundscan
  end
end
