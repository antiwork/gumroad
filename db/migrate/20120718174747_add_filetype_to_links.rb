# frozen_string_literal: true

class AddFiletypeToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :filetype, :string
  end
end
