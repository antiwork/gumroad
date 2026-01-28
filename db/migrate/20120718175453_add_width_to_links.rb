# frozen_string_literal: true

class AddWidthToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :width, :integer
  end
end
