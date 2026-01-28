# frozen_string_literal: true

class MakeDropboxUrlLonger < ActiveRecord::Migration[4.2]
  def change
    change_column :dropbox_files, :dropbox_url, :string, limit: 2000
    change_column :dropbox_files, :s3_url, :string, limit: 2000
  end
end
