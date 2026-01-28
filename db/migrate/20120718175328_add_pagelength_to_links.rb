# frozen_string_literal: true

class AddPagelengthToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :pagelength, :integer
  end
end
