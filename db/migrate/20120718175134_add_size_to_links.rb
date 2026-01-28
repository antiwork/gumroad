# frozen_string_literal: true

class AddSizeToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :size, :integer
  end
end
