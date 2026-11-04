# frozen_string_literal: true

class AddPingSigningSecretToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :ping_signing_secret, :string
  end
end
