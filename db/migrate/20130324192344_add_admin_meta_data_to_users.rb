# frozen_string_literal: true

class AddAdminMetaDataToUsers < ActiveRecord::Migration
  def change
    add_column :users, :admin_notes, :text
  end
end
