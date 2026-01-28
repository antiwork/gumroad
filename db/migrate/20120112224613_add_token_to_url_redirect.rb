# frozen_string_literal: true

class AddTokenToUrlRedirect < ActiveRecord::Migration[4.2]
  def change
    add_column :url_redirects, :token, :string
  end
end
