# frozen_string_literal: true

class AddCustomDownloadTextToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :custom_download_text, :string
  end
end
