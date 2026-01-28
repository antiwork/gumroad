# frozen_string_literal: true

class AddVersionsObjectChanges < ActiveRecord::Migration[4.2]
  def change
    add_column :versions, :object_changes, :text, size: :long
  end
end
