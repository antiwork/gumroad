# frozen_string_literal: true

class RenameWriterSequencesToKeyVersionsOnProductBuildSaves < ActiveRecord::Migration[8.1]
  def change
    rename_column :product_build_saves, :writer_sequences, :key_versions
  end
end
