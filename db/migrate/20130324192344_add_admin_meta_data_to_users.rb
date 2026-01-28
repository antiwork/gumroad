# frozen_string_literal: true

class AddAdminMetaDataToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :admin_notes, :text
  end
end
