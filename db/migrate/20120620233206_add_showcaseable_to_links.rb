# frozen_string_literal: true

class AddShowcaseableToLinks < ActiveRecord::Migration
  def change
    add_column :links, :showcaseable, :boolean, default: false
  end
end
