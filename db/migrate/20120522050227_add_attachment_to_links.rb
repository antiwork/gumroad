# frozen_string_literal: true

class AddAttachmentToLinks < ActiveRecord::Migration
  def self.up
    add_column :links, :attachment_file_name, :string
    add_column :links, :attachment_content_type, :string
    add_column :links, :attachment_file_size, :integer
    add_column :links, :attachment_updated_at, :datetime
    add_column :links, :attachment_guid, :string
  end

  def self.down
    remove_column :links, :attachment_file_name
    remove_column :links, :attachment_content_type
    remove_column :links, :attachment_file_size
    remove_column :links, :attachment_updated_at
    remove_column :links, :attachment_guid
  end
end
