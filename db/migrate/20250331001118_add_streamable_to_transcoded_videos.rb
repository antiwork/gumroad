# frozen_string_literal: true

class AddStreamableToTranscodedVideos < ActiveRecord::Migration[4.2]
  def change
    add_reference :transcoded_videos, :streamable, polymorphic: true, null: true
  end
end
