# frozen_string_literal: true

class RemoveOauthAuthorizations < ActiveRecord::Migration[4.2]
  def change
    drop_table :oauth_authorizations
  end
end
