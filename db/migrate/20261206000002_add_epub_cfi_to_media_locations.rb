# frozen_string_literal: true

class AddEpubCfiToMediaLocations < ActiveRecord::Migration[7.1]
  def change
    add_column :media_locations, :epub_cfi, :text
  end
end
