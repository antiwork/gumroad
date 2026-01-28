# frozen_string_literal: true

class AddGuidToAttachment < ActiveRecord::Migration[4.2]
  def change
    add_column :attachments, :file_guid, :string
  end
end
