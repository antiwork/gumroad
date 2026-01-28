# frozen_string_literal: true

class ChangeDescriptionToText < ActiveRecord::Migration[4.2]
  def up
    change_column :links, :description, :text
  end

  def down
    change_column :links, :description, :string
  end
end
