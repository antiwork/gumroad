# frozen_string_literal: true

class ChangeLinksNameNull < ActiveRecord::Migration[4.2]
  def change
    change_column_null :links, :name, false
  end
end
