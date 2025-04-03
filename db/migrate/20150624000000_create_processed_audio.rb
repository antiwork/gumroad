# frozen_string_literal: true

class CreateProcessedAudio < ActiveRecord::Migration
  def change
    create_table :processed_audios do |t|
      t.references :product_file
      t.string :url

      t.timestamps
      t.datetime :deleted_at
    end

    add_index :processed_audios, :product_file_id
  end
end
