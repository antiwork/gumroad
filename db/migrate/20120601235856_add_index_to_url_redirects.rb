# frozen_string_literal: true

class AddIndexToUrlRedirects < ActiveRecord::Migration
  def change
    add_index :url_redirects, :purchase_id
  end
end
