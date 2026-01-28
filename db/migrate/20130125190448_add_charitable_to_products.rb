# frozen_string_literal: true

class AddCharitableToProducts < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :is_charitable, :boolean, default: false
  end
end
