# frozen_string_literal: true

class AddVersionsObjectChanges < ActiveRecord::Migration[6.0]
  def change
    add_column :versions, :object_changes, :text, size: :long
  end
end
