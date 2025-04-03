# frozen_string_literal: true

class AddUnconfirmedEmailIndex < ActiveRecord::Migration
  def change
    add_index :users, :unconfirmed_email, name: "index_users_on_unconfirmed_email", length: 191
  end
end
