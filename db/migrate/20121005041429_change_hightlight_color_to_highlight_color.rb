# frozen_string_literal: true

class ChangeHightlightColorToHighlightColor < ActiveRecord::Migration
  def up
    rename_column :users, :hightlight_color, :highlight_color
  end

  def down
    rename_column :users, :highlight_color, :hightlight_color
  end
end
