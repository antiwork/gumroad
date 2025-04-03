# frozen_string_literal: true

class AddPreviewOembedToLinks < ActiveRecord::Migration
  def change
    add_column :links, :preview_oembed, :text
  end
end
