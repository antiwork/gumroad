# frozen_string_literal: true

class AddCustomizedFileUrlToUrlRedirects < ActiveRecord::Migration[4.2]
  def change
    add_column :url_redirects, :customized_file_url, :string
  end
end
