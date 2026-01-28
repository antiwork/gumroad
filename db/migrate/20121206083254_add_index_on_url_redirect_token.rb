# frozen_string_literal: true

class AddIndexOnUrlRedirectToken < ActiveRecord::Migration[4.2]
  def up
    add_index :url_redirects, :token
  end

  def down
    remove_index :url_redirects, :token
  end
end
