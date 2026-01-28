# frozen_string_literal: true

class ChangeWebhookedUrlToText < ActiveRecord::Migration[4.2]
  def up
    change_column :url_redirects, :webhooked_url, :text
  end

  def down
    change_column :url_redirects, :webhooked_url, :string
  end
end
