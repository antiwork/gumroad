# frozen_string_literal: true

class AddCustomHtmlToLinks < ActiveRecord::Migration[7.1]
  def change
    add_column :links, :custom_html, :longtext
  end
end
