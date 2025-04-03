# frozen_string_literal: true

class ChangeNamesToOriginal < ActiveRecord::Migration
  def up
    Attachment.find_each do |attachment|
      puts attachment.id
      original_file_name = attachment.file_file_name
      next unless original_file_name
      # base = File.basename(original_file_name)
      ext = File.extname(original_file_name)
      attachment.file_file_name = "original#{ext}"
      attachment.save(validate: false)
    end
  end

  def down
  end
end
