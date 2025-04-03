# frozen_string_literal: true

class IncreaseLengthOfS3UrlFields < ActiveRecord::Migration
  def change
    change_column(:product_files, :url, :string, limit: 1024)
    change_column(:processed_audios, :url, :string, limit: 1024)
    change_column(:product_files_archives, :url, :string, limit: 1024)
    change_column(:stamped_pdfs, :url, :string, limit: 1024)
    change_column(:subtitle_files, :url, :string, limit: 1024)
  end
end
