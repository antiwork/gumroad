# frozen_string_literal: true

class ChangePreviewUrlToText < ActiveRecord::Migration[4.2]
  def up
    change_column :links, :preview_url, :text
  end

  def down
    change_column :links, :preview_url, :text
  end
end
