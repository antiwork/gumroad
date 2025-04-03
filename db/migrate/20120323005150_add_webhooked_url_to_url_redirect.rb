# frozen_string_literal: true

class AddWebhookedUrlToUrlRedirect < ActiveRecord::Migration
  def change
    add_column :url_redirects, :webhooked_url, :string
  end
end
