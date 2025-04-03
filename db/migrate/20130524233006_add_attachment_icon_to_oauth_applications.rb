# frozen_string_literal: true

class AddAttachmentIconToOauthApplications < ActiveRecord::Migration
  def self.up
    change_table :oauth_applications do |t|
      t.has_attached_file :icon
    end
  end

  def self.down
    drop_attached_file :oauth_applications, :icon
  end
end
