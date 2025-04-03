# frozen_string_literal: true

class ChangeLinksNameNull < ActiveRecord::Migration[6.1]
  def change
    change_column_null :links, :name, false
  end
end
