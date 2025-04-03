# frozen_string_literal: true

class AddGuidToAttachment < ActiveRecord::Migration
  def change
    add_column :attachments, :file_guid, :string
  end
end
