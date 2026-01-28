# frozen_string_literal: true

class AddKindleEmailToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :kindle_email, :string
  end
end
