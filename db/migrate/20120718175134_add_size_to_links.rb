# frozen_string_literal: true

class AddSizeToLinks < ActiveRecord::Migration
  def change
    add_column :links, :size, :integer
  end
end
