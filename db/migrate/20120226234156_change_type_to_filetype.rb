# frozen_string_literal: true

class ChangeTypeToFiletype < ActiveRecord::Migration[4.2]
  def up
    remove_column :infos, :type
    add_column :infos, :filetype, :string
  end

  def down
    remove_column :infos, :filetype
  end
end
