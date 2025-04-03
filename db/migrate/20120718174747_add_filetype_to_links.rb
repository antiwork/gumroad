# frozen_string_literal: true

class AddFiletypeToLinks < ActiveRecord::Migration
  def change
    add_column :links, :filetype, :string
  end
end
