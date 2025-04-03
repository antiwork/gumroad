# frozen_string_literal: true

class AddSupportEmailToUsers < ActiveRecord::Migration
  def change
    add_column :users, :support_email, :string
  end
end
