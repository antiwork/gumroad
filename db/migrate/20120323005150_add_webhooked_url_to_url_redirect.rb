# frozen_string_literal: true

class AddWebhookedUrlToUrlRedirect < ActiveRecord::Migration[4.2]
  def change
    add_column :url_redirects, :webhooked_url, :string
  end
end
