# frozen_string_literal: true

class AddIndexToUrlRedirects < ActiveRecord::Migration[4.2]
  def change
    add_index :url_redirects, :purchase_id
  end
end
