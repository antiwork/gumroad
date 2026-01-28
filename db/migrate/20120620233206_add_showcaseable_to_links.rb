# frozen_string_literal: true

class AddShowcaseableToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :showcaseable, :boolean, default: false
  end
end
