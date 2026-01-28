# frozen_string_literal: true

class AddUnconfirmedEmailIndex < ActiveRecord::Migration[4.2]
  def change
    add_index :users, :unconfirmed_email, name: "index_users_on_unconfirmed_email", length: 191
  end
end
