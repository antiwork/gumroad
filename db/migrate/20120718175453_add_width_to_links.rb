# frozen_string_literal: true

class AddWidthToLinks < ActiveRecord::Migration
  def change
    add_column :links, :width, :integer
  end
end
