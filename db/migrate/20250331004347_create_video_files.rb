# frozen_string_literal: true

class CreateVideoFiles < ActiveRecord::Migration[7.1]
  def change
    create_table :video_files do |t|
      t.references :record, polymorphic: true, null: false

      t.string :url                  # S3 URL of the original file
      t.string :filetype             # File extension (e.g., "mp4")

      # Metadata populated during analysis.
      t.integer :width               # Video width in pixels
      t.integer :height              # Video height in pixels
      t.integer :duration            # Duration in seconds
      t.integer :bitrate             # Bitrate of the video
      t.integer :framerate           # Frame rate of the video
      t.integer :size                # File size in bytes

      t.integer :flags, default: 0   # For FlagShihTzu booleans

      t.datetime :deleted_at
      t.datetime :deleted_from_cdn_at

      t.timestamps
    end
  end
end
