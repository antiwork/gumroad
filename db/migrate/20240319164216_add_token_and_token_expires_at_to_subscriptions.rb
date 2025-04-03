# frozen_string_literal: true

class AddTokenAndTokenExpiresAtToSubscriptions < ActiveRecord::Migration[7.1]
  def change
    change_table :subscriptions, bulk: true do |t|
      t.string :token
      t.datetime :token_expires_at
    end
  end
end
