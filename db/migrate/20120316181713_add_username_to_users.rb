# frozen_string_literal: true

class AddUsernameToUsers < ActiveRecord::Migration
  def change
    change_table :users do |t|
      t.string :username
    end
  end
end
