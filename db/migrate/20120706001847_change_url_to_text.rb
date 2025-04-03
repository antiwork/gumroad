# frozen_string_literal: true

class ChangeUrlToText < ActiveRecord::Migration
  def up
    change_column :links, :url, :text
  end

  def down
    change_column :links, :url, :string
  end
end
