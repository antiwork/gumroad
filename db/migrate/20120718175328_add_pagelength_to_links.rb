# frozen_string_literal: true

class AddPagelengthToLinks < ActiveRecord::Migration
  def change
    add_column :links, :pagelength, :integer
  end
end
