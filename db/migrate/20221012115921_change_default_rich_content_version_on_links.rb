# frozen_string_literal: true

class ChangeDefaultRichContentVersionOnLinks < ActiveRecord::Migration[4.2]
  def up
    change_column_default :links, :rich_content_version, 1
  end

  def down
    change_column_default :links, :rich_content_version, 0
  end
end
