# frozen_string_literal: true

class AddHighlightColorToUsers < ActiveRecord::Migration
  def change
    add_column :users, :hightlight_color, :string
  end
end
