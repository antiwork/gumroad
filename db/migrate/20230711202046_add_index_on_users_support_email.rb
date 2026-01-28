# frozen_string_literal: true

class AddIndexOnUsersSupportEmail < ActiveRecord::Migration[4.2]
  def change
    add_index :users, :support_email
  end
end
