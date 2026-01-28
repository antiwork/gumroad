# frozen_string_literal: true

class AddHighlightColorToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :hightlight_color, :string
  end
end
