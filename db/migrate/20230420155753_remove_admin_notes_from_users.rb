# frozen_string_literal: true

class RemoveAdminNotesFromUsers < ActiveRecord::Migration[4.2]
  def change
    remove_column :users, :admin_notes, :text, size: :medium
  end
end
