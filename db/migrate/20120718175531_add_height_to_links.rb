# frozen_string_literal: true

class AddHeightToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :height, :integer
  end
end
