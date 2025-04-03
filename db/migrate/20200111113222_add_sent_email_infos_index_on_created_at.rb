# frozen_string_literal: true

class AddSentEmailInfosIndexOnCreatedAt < ActiveRecord::Migration
  def up
    add_index :sent_email_infos, :created_at
  end

  def down
    remove_index :sent_email_infos, :created_at
  end
end
