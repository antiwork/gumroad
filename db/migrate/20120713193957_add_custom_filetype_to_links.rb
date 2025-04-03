# frozen_string_literal: true

class AddCustomFiletypeToLinks < ActiveRecord::Migration
  def change
    add_column :links, :custom_filetype, :string
  end
end
