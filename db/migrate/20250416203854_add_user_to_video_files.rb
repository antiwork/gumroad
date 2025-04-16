# frozen_string_literal: true

class AddUserToVideoFiles < ActiveRecord::Migration[7.1]
  def change
    add_reference :video_files, :user, null: false, foreign_key: false
  end
end
