# frozen_string_literal: true

class AddCustomizedFileUrlToUrlRedirects < ActiveRecord::Migration
  def change
    add_column :url_redirects, :customized_file_url, :string
  end
end
