# frozen_string_literal: true

class AddDefaultForFiletype < ActiveRecord::Migration
  def up
    change_column :links, :filetype, :string, default: "link"
    change_column :links, :filegroup, :string, default: "url"
  end

  def down
    change_column :links, :filetype, :string, default: nil
    change_column :links, :filegroup, :string, default: nil
  end
end
