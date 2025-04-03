# frozen_string_literal: true

class DisabledAt < ActiveRecord::Migration
  def up
    add_column :links, :purchase_disabled_at, :datetime
  end

  def down
    remove_column :links, :purchase_disabled_at, :datetime
  end
end
