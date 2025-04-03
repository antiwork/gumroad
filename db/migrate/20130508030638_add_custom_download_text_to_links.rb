# frozen_string_literal: true

class AddCustomDownloadTextToLinks < ActiveRecord::Migration
  def change
    add_column :links, :custom_download_text, :string
  end
end
