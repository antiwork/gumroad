# frozen_string_literal: true

class AddDefaultToUrlRedirectUses < ActiveRecord::Migration[4.2]
  def change
    change_column :url_redirects, :uses, :integer, default: 0
  end
end
