# frozen_string_literal: true

class AddCustomFiletypeToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :custom_filetype, :string
  end
end
