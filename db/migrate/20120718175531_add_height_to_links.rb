# frozen_string_literal: true

class AddHeightToLinks < ActiveRecord::Migration
  def change
    add_column :links, :height, :integer
  end
end
