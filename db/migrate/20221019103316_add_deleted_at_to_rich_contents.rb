# frozen_string_literal: true

class AddDeletedAtToRichContents < ActiveRecord::Migration[4.2]
  def change
    add_column :rich_contents, :deleted_at, :datetime
  end
end
