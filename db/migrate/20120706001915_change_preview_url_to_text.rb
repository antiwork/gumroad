# frozen_string_literal: true

class ChangePreviewUrlToText < ActiveRecord::Migration
  def up
    change_column :links, :preview_url, :text
  end

  def down
    change_column :links, :preview_url, :text
  end
end
