# frozen_string_literal: true

class AddAttachmentMeta < ActiveRecord::Migration
  def up
    add_column :attachments, :file_meta, :text
  end

  def down
    remove_column :attachments, :file_meta
  end
end
