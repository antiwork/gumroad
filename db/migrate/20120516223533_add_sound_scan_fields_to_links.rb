# frozen_string_literal: true

class AddSoundScanFieldsToLinks < ActiveRecord::Migration
  def change
    add_column :links, :soundscan, :boolean
    add_column :links, :upc_code, :string
    add_column :links, :isrc_code, :string
  end
end
