# frozen_string_literal: true

class AddExternalIdToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :external_id, :string
  end
end
