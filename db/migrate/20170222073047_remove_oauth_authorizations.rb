# frozen_string_literal: true

class RemoveOauthAuthorizations < ActiveRecord::Migration
  def change
    drop_table :oauth_authorizations
  end
end
