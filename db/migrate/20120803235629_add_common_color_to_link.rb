# frozen_string_literal: true

class AddCommonColorToLink < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :common_color, :string
  end
end
