# frozen_string_literal: true

class LinkSoftDelete < ActiveRecord::Migration
  def up
    add_column :links, :deleted_at, :datetime
  end

  def down
    remove_column :links, :deleted_at
  end
end
