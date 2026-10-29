# frozen_string_literal: true

class AddWriterToProductBuildSaves < ActiveRecord::Migration[8.1]
  def change
    add_column :product_build_saves, :writer_sequences, :json
  end
end
