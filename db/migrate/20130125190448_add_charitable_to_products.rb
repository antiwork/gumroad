# frozen_string_literal: true

class AddCharitableToProducts < ActiveRecord::Migration
  def change
    add_column :links, :is_charitable, :boolean, default: false
  end
end
