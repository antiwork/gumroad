# frozen_string_literal: true

class AddTokenToUrlRedirect < ActiveRecord::Migration
  def change
    add_column :url_redirects, :token, :string
  end
end
