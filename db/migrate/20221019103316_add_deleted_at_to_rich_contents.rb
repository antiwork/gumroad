# frozen_string_literal: true

class AddDeletedAtToRichContents < ActiveRecord::Migration[6.1]
  def change
    add_column :rich_contents, :deleted_at, :datetime
  end
end
