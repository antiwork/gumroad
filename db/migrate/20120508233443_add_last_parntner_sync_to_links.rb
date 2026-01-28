# frozen_string_literal: true

class AddLastParntnerSyncToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :last_partner_sync, :timestamp
  end
end
