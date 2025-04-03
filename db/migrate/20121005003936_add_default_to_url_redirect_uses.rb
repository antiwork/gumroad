# frozen_string_literal: true

class AddDefaultToUrlRedirectUses < ActiveRecord::Migration
  def change
    change_column :url_redirects, :uses, :integer, default: 0
  end
end
