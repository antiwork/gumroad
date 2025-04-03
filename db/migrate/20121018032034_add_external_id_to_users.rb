# frozen_string_literal: true

class AddExternalIdToUsers < ActiveRecord::Migration
  def change
    add_column :users, :external_id, :string
  end
end
