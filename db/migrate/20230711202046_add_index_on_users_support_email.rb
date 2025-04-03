# frozen_string_literal: true

class AddIndexOnUsersSupportEmail < ActiveRecord::Migration[7.0]
  def change
    add_index :users, :support_email
  end
end
