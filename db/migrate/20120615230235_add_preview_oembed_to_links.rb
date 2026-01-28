# frozen_string_literal: true

class AddPreviewOembedToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :preview_oembed, :text
  end
end
