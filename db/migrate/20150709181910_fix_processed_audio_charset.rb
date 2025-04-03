# frozen_string_literal: true

class FixProcessedAudioCharset < ActiveRecord::Migration
  def change
    execute("ALTER TABLE processed_audios CONVERT TO CHARACTER SET utf8 COLLATE utf8_unicode_ci;")
  end
end
